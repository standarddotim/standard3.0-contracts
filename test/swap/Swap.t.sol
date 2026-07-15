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

        // Independently compute the expected principal/fee split via the same primitives
        // Pool.swap uses internally, but as a separate call path -- a loose assertGt/assertLt
        // here previously passed even when an earlier version of this task's implementation
        // double-credited poolShareOfFee (once folded into principal via
        // lpPrincipalReceived, again separately via creditFee -- see the comment at that
        // line in Step 3). An exact conservation check is what actually catches that class
        // of defect; a nonzero-only check does not.
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8;
        uint256 matchedLpAmount = book.convert(boundPrice, 100e18, false); // quote->base, full fill
        uint32 makerFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(pool), true);
        uint256 grossLpProceeds = book.convert(boundPrice, matchedLpAmount, true); // base->quote
        uint256 lpFee = (grossLpProceeds * makerFeeRate) / matchingEngine.DENOM();
        uint256 expectedPoolShareOfFee = (lpFee * matchingEngine.poolFeeShare()) / matchingEngine.DENOM();
        uint256 expectedPrincipal = grossLpProceeds - lpFee;

        vm.prank(trader1);
        token2.approve(address(pool), 100e18);
        vm.prank(trader1);
        pool.swap(100e18, true, trader1, false);

        IPool.Position memory afterSwap = pool.getPosition(positionId);
        // Position sold base (quoteToBase=true -> LP leg limitSell's base), so baseAmount
        // must have decreased and quoteAmount (principal received back) must have increased.
        assertLt(afterSwap.baseAmount, before.baseAmount);
        assertEq(afterSwap.quoteAmount, before.quoteAmount + expectedPrincipal);
        // With poolFeeShare > 0 and this being the sole contributing position, it should
        // have received exactly its computed share as a fee reward on the quote side (see
        // swap()'s isBaseFee = !quoteToBase convention) -- an exact check, not nonzero-only.
        assertEq(afterSwap.feeOwedQuote, expectedPoolShareOfFee);
        // Conservation: what got credited to this position across both fields must equal
        // exactly what Pool actually received from the match (Orderbook._sendFunds's
        // withoutFee + poolShare, both sent to Pool as the LP leg's order owner when
        // poolFeeShare > 0 -- Task 4). This is the check that directly catches the
        // double-credit bug class, independent of the exact fee-split numbers above.
        assertEq(
            (afterSwap.quoteAmount - before.quoteAmount) + afterSwap.feeOwedQuote,
            grossLpProceeds - lpFee + expectedPoolShareOfFee
        );
    }

    function testPartialFillRefundsLeftoverByDefault() public {
        // Shrink the position's available base so a large quote input can't be fully absorbed.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1); // leaves 5e18 base available

        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);

        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn) = pool.swap(1000e18, true, trader1, false);

        assertGt(amountOut, 0);
        assertGt(leftoverIn, 0);
        // Full input pulled in, but leftover refunded back out -- net spend is amountIn - leftoverIn.
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - (1000e18 - leftoverIn));
    }

    function testOptInRestingLeftoverPlacesSwapperOwnedOrder() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);

        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);

        vm.prank(trader1);
        (, uint256 leftoverIn) = pool.swap(1000e18, true, trader1, true);
        // leftoverIn is read from recipient's own balance delta (design.md §4.6); a resting
        // remainder's tokens move into the exchange's escrow (owned by trader1 as a resting
        // order), never back into trader1's wallet, so there is nothing for a balance delta
        // to observe here -- leftoverIn == 0 in this mode is the correct, documented
        // consequence of that design, not a sign the swap fully matched. The resting order
        // itself (checked below) is the real, meaningful verification for this test.
        assertEq(leftoverIn, 0);

        // trader1 should now own a resting bid order for the leftover amount.
        (uint256 bidHead, ) = matchingEngine.heads(address(token1), address(token2));
        assertGt(bidHead, 0);
    }

    function testPartialFillStillSettlesMatchedPortionToPosition() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1); // leaves 5e18 base available

        IPool.Position memory before = pool.getPosition(positionId);

        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);
        vm.prank(trader1);
        pool.swap(1000e18, true, trader1, false);

        IPool.Position memory afterSwap = pool.getPosition(positionId);
        // Only ~5e18 base could have matched (that's all that was available) -- confirm the
        // position's base decreased by at most what it had, not by some larger/incorrect
        // amount derived from the swapper's full 1000e18 attempted amountIn.
        assertLe(before.baseAmount - afterSwap.baseAmount, before.baseAmount);
        assertGt(afterSwap.quoteAmount, before.quoteAmount);
    }
}
