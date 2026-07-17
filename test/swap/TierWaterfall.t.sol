// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

// Covers the tiered LP-leg mechanics: per-tier execution bounds (a position's fill terms
// are its OWN quoted tolerance), the within-tier waterfall by age (the paper's §4.6 JIT
// defense), and balance-delta settlement (better-priced third-party crossings accrue to
// positions instead of stranding in the pool).
contract TierWaterfallTest is PoolBaseSetup {
    function setUp() public override {
        super.setUp();
        vm.prank(lp1);
        token1.approve(address(pool), 10000000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000000e18);
        vm.prank(lp2);
        token1.approve(address(pool), 10000000e18);
        vm.prank(lp2);
        token2.approve(address(pool), 10000000e18);
    }

    // Two positions at the SAME tolerance: the older one must be exhausted before the
    // younger supplies anything -- volume or fees. This is the JIT defense made literal: a
    // same-block copycat deposit at an incumbent's tolerance takes nothing while the
    // incumbent still has inventory.
    function testSameToleranceWaterfallProtectsOlderPosition() public {
        vm.prank(positionManager);
        uint256 older = pool.addLiquidity(50e8, 150e8, 5000000, 10e18, 0, lp1);
        vm.prank(positionManager);
        uint256 jit = pool.addLiquidity(50e8, 150e8, 5000000, 10e18, 0, lp2);

        // Buy roughly half the OLDER position's base: 5e18 base at the 5% bound
        // (105e8) costs 525e18 quote.
        vm.prank(trader1);
        token2.approve(address(pool), 525e18);
        vm.prank(trader1);
        (uint256 amountOut,) = pool.swap(525e18, true, trader1, false);
        assertGt(amountOut, 0);

        IPool.Position memory olderAfter = pool.getPosition(older);
        IPool.Position memory jitAfter = pool.getPosition(jit);

        // The older position supplied everything that matched...
        assertLt(olderAfter.baseAmount, 10e18);
        assertGt(olderAfter.quoteAmount, 0);
        // ...and the younger same-tolerance position supplied and earned NOTHING.
        assertEq(jitAfter.baseAmount, 10e18);
        assertEq(jitAfter.quoteAmount, 0);
        assertEq(jitAfter.feeOwedBase, 0);
        assertEq(jitAfter.feeOwedQuote, 0);
    }

    // Two positions at DIFFERENT tolerances: the tighter tier fills first (book price
    // priority) and each position's credit reflects its own tier's bound, not a pool-wide
    // minimum -- the paper's per-position-s income model (§3.4).
    function testTighterTierFillsFirstAndEachAtItsOwnBound() public {
        vm.prank(positionManager);
        uint256 tight = pool.addLiquidity(50e8, 150e8, 1000000, 3e18, 0, lp1); // s = 1%
        vm.prank(positionManager);
        uint256 wide = pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 0, lp2); // s = 5%

        // Spend enough quote to consume the tight tier (3e18 base at ~101 = ~303e18) and
        // bite well into the wide tier.
        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);
        vm.prank(trader1);
        (uint256 amountOut,) = pool.swap(1000e18, true, trader1, false);
        assertGt(amountOut, 0);

        IPool.Position memory tightAfter = pool.getPosition(tight);
        IPool.Position memory wideAfter = pool.getPosition(wide);

        // Price priority: the tight tier is fully consumed before the wide tier finishes.
        assertEq(tightAfter.baseAmount, 0);
        assertGt(wideAfter.baseAmount, 0);
        assertLt(wideAfter.baseAmount, 1000e18);

        // Each position's principal reflects ITS OWN bound net of the maker fee. The
        // engine's per-fill rounding can add a few wei (credited, not stranded), so the
        // reconstruction brackets from below with a tight absolute tolerance.
        uint32 makerFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(pool), true);

        uint256 tightGross = book.convert((100e8 * (1e8 + 1000000)) / 1e8, 3e18, true);
        uint256 tightExpected = tightGross - (tightGross * makerFeeRate) / matchingEngine.DENOM();
        assertApproxEqAbs(tightAfter.quoteAmount, tightExpected, 2000);

        uint256 wideUsed = 1000e18 - wideAfter.baseAmount;
        uint256 wideGross = book.convert((100e8 * (1e8 + 5000000)) / 1e8, wideUsed, true);
        uint256 wideExpected = wideGross - (wideGross * makerFeeRate) / matchingEngine.DENOM();
        assertApproxEqAbs(wideAfter.quoteAmount, wideExpected, 2000);

        // Sanity: per unit of base supplied, the wide tier earned a strictly better price
        // than the tight tier -- the LP's self-quoted spread is its income.
        assertGt(wideAfter.quoteAmount * 1e18 / wideUsed, tightAfter.quoteAmount * 1e18 / 3e18);
    }

    // A pre-existing third-party bid ABOVE the tier bound: the LP leg crosses it at the
    // better price, and that surplus must be credited to the contributing position --
    // conservation against the pool's measured balance delta, the G8 fix.
    function testBetterPricedThirdPartyCrossingCreditsPositionNotPool() public {
        vm.prank(positionManager);
        uint256 positionId = pool.addLiquidity(50e8, 150e8, 5000000, 10e18, 0, lp1);

        // trader2 rests a bid at 107e8 (inside the 10% admin spread) for 5e18 base worth
        // of quote -- strictly better than the LP tier's 105e8 ask bound.
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 107e8, 535e18, true, 20, trader2);

        uint256 poolQuoteBefore = token2.balanceOf(address(pool));

        vm.prank(trader1);
        token2.approve(address(pool), 525e18);
        vm.prank(trader1);
        pool.swap(525e18, true, trader1, false);

        uint256 actualProceeds = token2.balanceOf(address(pool)) - poolQuoteBefore;
        IPool.Position memory p = pool.getPosition(positionId);

        // The position received MORE than its own bound would reconstruct (the 107e8
        // crossing), and everything the pool was paid landed on the position: principal
        // plus fee credit equals the measured delta exactly -- nothing stranded.
        uint256 used = 10e18 - p.baseAmount;
        uint256 boundGross = book.convert(105e8, used, true);
        uint32 makerFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(pool), true);
        uint256 boundExpected = boundGross - (boundGross * makerFeeRate) / matchingEngine.DENOM();
        assertGt(p.quoteAmount, boundExpected);
        assertEq(p.quoteAmount + p.feeOwedQuote, actualProceeds);
    }

    // G6 guard: a tolerance at or above 100% is rejected at deposit time -- previously a
    // single such position could brick every base->quote swap in its range via underflow.
    function testAddLiquidityRejectsSlippageAtOrAboveDenom() public {
        vm.prank(positionManager);
        vm.expectRevert(abi.encodeWithSelector(IPool.InvalidSlippageLimit.selector, uint32(1e8)));
        pool.addLiquidity(50e8, 150e8, 1e8, 10e18, 0, lp1);
    }
}
