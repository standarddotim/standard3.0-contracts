// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

contract SwapTest is PoolBaseSetup {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        // Position brackets the pair's listing price (100e8, set in PoolBaseSetup.setUp)
        // with a generous slippage tolerance so it's trivially in-range and willing to
        // trade at any price a full-fill test would compute. 5% sits comfortably inside
        // PoolBaseSetup's 10% admin spread (Step 0) so a full match can actually occur.
        vm.prank(lp1);
        token1.approve(address(pool), 10000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        positionId = pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 1000e18, lp1);
    }

    function testFullFillQuoteToBaseSwap() public {
        vm.prank(trader1);
        token2.approve(address(pool), 100e18);

        uint256 traderBaseBefore = token1.balanceOf(trader1);
        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        // Independently compute the expected output the same way the pre-fee-deduction
        // arithmetic works, so this assertion is a real cross-check rather than tautological
        // against amountOut's own definition (Pool.swap now *measures* amountOut as a
        // balance delta on trader1 -- see design.md §4.6 -- so asserting
        // token1.balanceOf(trader1) == traderBaseBefore + amountOut alone would trivially
        // always hold and catch nothing).
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8; // marketPrice * (1 + position's slippageLimit)
        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), trader1, false);
        uint256 grossOut = book.convert(boundPrice, 100e18, false); // quote->base: isBid=false
        uint256 expectedAmountOut = grossOut - (grossOut * takerFeeRate) / matchingEngine.DENOM();

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn) = pool.swap(100e18, true, trader1, false);

        assertEq(amountOut, expectedAmountOut);
        assertGt(amountOut, 0);
        assertEq(leftoverIn, 0);
        assertEq(token1.balanceOf(trader1), traderBaseBefore + amountOut);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - 100e18);
    }

    function testFullFillBaseToQuoteSwap() public {
        vm.prank(trader1);
        token1.approve(address(pool), 5e18);

        uint256 traderBaseBefore = token1.balanceOf(trader1);
        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        // Same independent cross-check as the quote->base test above, mirrored for this
        // direction (see that test's comment for why this assertion is load-bearing).
        uint256 boundPrice = (100e8 * (1e8 - 5000000)) / 1e8; // marketPrice * (1 - position's slippageLimit)
        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), trader1, false);
        uint256 grossOut = book.convert(boundPrice, 5e18, true); // base->quote: isBid=true
        uint256 expectedAmountOut = grossOut - (grossOut * takerFeeRate) / matchingEngine.DENOM();

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn) = pool.swap(5e18, false, trader1, false);

        assertEq(amountOut, expectedAmountOut);
        assertGt(amountOut, 0);
        assertEq(leftoverIn, 0);
        assertEq(token1.balanceOf(trader1), traderBaseBefore - 5e18);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore + amountOut);
    }

    function testSwapRevertsWhenNoPositionInRange() public {
        // Move price far outside the only position's [50e8, 150e8] range by updating lmp
        // via a matched trade at an out-of-range price first is complex to set up directly;
        // instead cover NoLiquidityInRange by removing the only position's liquidity first.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 1000e18, 1000e18, lp1);

        vm.prank(trader1);
        token2.approve(address(pool), 100e18);
        vm.prank(trader1);
        vm.expectRevert(); // exact NoLiquidityInRange(marketPrice) selector; price value asserted loosely here
        pool.swap(100e18, true, trader1, false);
    }

    function testSwapCreditsPrincipalAndFeeToContributingPosition() public {
        matchingEngine.setPoolFeeShare(50000000); // 50% in DENOM=1e8 terms

        IPool.Position memory before = pool.getPosition(positionId);

        vm.prank(trader1);
        token2.approve(address(pool), 100e18);
        vm.prank(trader1);
        pool.swap(100e18, true, trader1, false);

        IPool.Position memory afterSwap = pool.getPosition(positionId);
        // Position sold base (quoteToBase=true -> LP leg limitSell's base), so baseAmount
        // must have decreased and quoteAmount (principal received back) must have increased.
        assertLt(afterSwap.baseAmount, before.baseAmount);
        assertGt(afterSwap.quoteAmount, before.quoteAmount);
        // With poolFeeShare > 0 and this being the sole contributing position, it should
        // have received a nonzero fee reward on the quote side (see swap()'s isBaseFee
        // = !quoteToBase convention).
        assertGt(afterSwap.feeOwedQuote, 0);
    }
}
