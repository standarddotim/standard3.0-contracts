// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract RouterTest is PoolBaseSetup {
    SwapRouter router;
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));

        vm.prank(lp1);
        token1.approve(address(pool), 10000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        positionId = pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 1000e18, lp1);
    }

    function testSingleHopSwap() public {
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn) = router.swap(path, 100e18, 0, trader1, false);

        assertGt(amountOut, 0);
        assertEq(leftoverIn, 0);
        assertGt(token1.balanceOf(trader1), 0);
    }

    function testSingleHopSwapRevertsBelowMinAmountOut() public {
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        vm.prank(trader1);
        vm.expectRevert();
        router.swap(path, 100e18, type(uint256).max, trader1, false);
    }

    function testSwapRevertsForUnknownPool() public {
        // Approve first -- without this, the call reverts at the initial
        // TransferHelper.safeTransferFrom (missing allowance) before ever reaching the pool
        // lookup, and a bare vm.expectRevert() would pass either way without proving
        // PoolDoesNotExist actually fires (found in review: the original version of this
        // test had no approve call and provided zero real coverage of this router's one
        // genuinely new revert path).
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(0xDEAD);

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(ISwapRouter.PoolDoesNotExist.selector, address(token2), address(0xDEAD)));
        router.swap(path, 100e18, 0, trader1, false);
    }

    function testMultiHopSwapChainsThroughTwoPools() public {
        // Second pair: token1(base)/token3(quote), so path is token2 -> token1 -> token3.
        // Uses a second plain MockQuote (mirroring Tasks 12-14's token3/token4 pattern)
        // rather than PoolBaseSetup's weth field: Orderbook._sendFunds unconditionally
        // unwraps WETH to native ETH on settlement (Orderbook.sol:367-370), regardless of
        // how the pair was listed, and Pool.swap's amountOut/leftoverIn accounting
        // (design.md Sec4.6) reads ERC20 balance deltas -- so a WETH leg's real
        // native-ETH payout would never show up as a WETH balance change, making Pool.swap
        // silently report amountOut=0 for a leg that actually filled. This is a genuine,
        // pre-existing interaction between the audited exchange's WETH-unwrap behavior and
        // the swap module's balance-delta design that this task's own scope (verify the
        // router's multi-hop loop) doesn't need to resolve -- see design.md Sec10 for the
        // tracked limitation. A plain second ERC20 sidesteps it entirely while still
        // genuinely exercising 2 distinct pools chained together.
        MockQuote token3 = new MockQuote("Quote2", "QUOTE2");
        token3.mint(lp1, 10000e18);

        matchingEngine.addPair(address(token1), address(token3), 1e8, 1, address(token1), ExchangeOrderbook.MatchingMode.SizePriority);
        Pool secondPool = Pool(poolFactory.getPool(address(token1), address(token3)));
        // Advance past listing so Pool.swap's twap(TWAP_WINDOW) call (Task 10) has enough
        // oracle history for THIS pair too -- PoolBaseSetup's one-time warp in setUp() only
        // covers the pair listed there (token1/token2); this pair is listed later, at
        // whatever block.timestamp setUp()'s warp already advanced to, with zero elapsed
        // seconds of its own history until this pair gets its own warp (found before
        // implementation: without this, the multi-hop test that genuinely reaches this
        // pool's swap() leg reverts InsufficientHistory).
        vm.warp(block.timestamp + 600);

        vm.prank(lp1);
        token1.approve(address(secondPool), 1000e18);
        vm.prank(lp1);
        token3.approve(address(secondPool), 1000e18);
        vm.prank(positionManager);
        // Range must bracket this pool's own listing price (1e8, set above), not the
        // token1/token2 pool's listing price (100e8) that the [50e8,150e8] range used
        // elsewhere in this file was sized for -- Pool._prepareSwap's marketPrice comes from
        // this pool's own orderbook TWAP (tracking its 1e8 listing price), and
        // _assembleInRangePositions only counts a position whose [minPrice,maxPrice] contains
        // that marketPrice, so [50e8,150e8] here left this position permanently out of range
        // and any real swap reaching this pool reverted NoLiquidityInRange(1e8) (found while
        // running this task's tests: same 50%-150%-of-listing-price bracket as the other
        // pool, rescaled to this pool's 1e8 listing price).
        secondPool.addLiquidity(5e7, 15e7, 5000000, 500e18, 500e18, lp1);

        vm.prank(trader1);
        token2.approve(address(router), 50e18);

        address[] memory path = new address[](3);
        path[0] = address(token2);
        path[1] = address(token1);
        path[2] = address(token3);

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn) = router.swap(path, 50e18, 0, trader1, false);

        assertGt(amountOut, 0);
        assertEq(leftoverIn, 0);
        assertGt(token3.balanceOf(trader1), 0);
    }

    function testMidPathPartialFillRevertsEntirePath() public {
        // Shrink the first hop's available liquidity so hop 1 can only partially fill.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);

        // Same plain-ERC20 substitution as testMultiHopSwapChainsThroughTwoPools above, and
        // for the same reason (avoid Orderbook._sendFunds's unconditional WETH auto-unwrap
        // interacting badly with Pool.swap's ERC20-balance-delta accounting).
        MockQuote token3 = new MockQuote("Quote2", "QUOTE2");
        token3.mint(lp1, 10000e18);

        matchingEngine.addPair(address(token1), address(token3), 1e8, 1, address(token1), ExchangeOrderbook.MatchingMode.SizePriority);
        Pool secondPool = Pool(poolFactory.getPool(address(token1), address(token3)));
        // Advance past listing so Pool.swap's twap(TWAP_WINDOW) call (Task 10) has enough
        // oracle history for THIS pair too -- PoolBaseSetup's one-time warp in setUp() only
        // covers the pair listed there (token1/token2); this pair is listed later, at
        // whatever block.timestamp setUp()'s warp already advanced to, with zero elapsed
        // seconds of its own history until this pair gets its own warp (found before
        // implementation: without this, the multi-hop test that genuinely reaches this
        // pool's swap() leg reverts InsufficientHistory).
        vm.warp(block.timestamp + 600);
        vm.prank(lp1);
        token1.approve(address(secondPool), 1000e18);
        vm.prank(lp1);
        token3.approve(address(secondPool), 1000e18);
        vm.prank(positionManager);
        // Range must bracket this pool's own listing price (1e8, set above), not the
        // token1/token2 pool's listing price (100e8) that the [50e8,150e8] range used
        // elsewhere in this file was sized for -- Pool._prepareSwap's marketPrice comes from
        // this pool's own orderbook TWAP (tracking its 1e8 listing price), and
        // _assembleInRangePositions only counts a position whose [minPrice,maxPrice] contains
        // that marketPrice, so [50e8,150e8] here left this position permanently out of range
        // and any real swap reaching this pool reverted NoLiquidityInRange(1e8) (found while
        // running this task's tests: same 50%-150%-of-listing-price bracket as the other
        // pool, rescaled to this pool's 1e8 listing price).
        secondPool.addLiquidity(5e7, 15e7, 5000000, 500e18, 500e18, lp1);

        vm.prank(trader1);
        token2.approve(address(router), 1000e18);

        address[] memory path = new address[](3);
        path[0] = address(token2);
        path[1] = address(token1);
        path[2] = address(token3);

        // A non-final hop's partial fill now reverts the whole transaction (final
        // whole-branch review, finding C1): an earlier version tried to gracefully refund
        // only the unfilled input, silently stranding whatever this hop had already
        // produced in the router's own balance -- real, confirmed fund loss, since nothing
        // ever swept it back out. Revert is the fix, matching the design doc's own stated
        // intent ("refund the whole path"): Solidity's atomicity means every state change
        // in this call, including hop 1's real match against the order book and the initial
        // pull from the trader, unwinds together.
        //
        // Independently compute the expected unfilledAmount the same way _executeHop's
        // underlying Pool.swap does: the shrunk position offers exactly 5e18 base (all of
        // it, since 1000e18 quote demand vastly exceeds it), matched at this pool's own
        // 5% slippage bound (100e8 * 1.05 = 105e8); converting that matched base back to
        // quote terms gives what actually got spent, and the remainder is what leftoverIn
        // (and therefore MidPathPartialFill's unfilledAmount) must equal. Asserting the
        // exact selector+args (not a bare vm.expectRevert()) proves it's genuinely this new
        // guard firing on the exact right amount, not some unrelated failure that would
        // also happen to revert.
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8;
        uint256 matchedQuoteSpent = book.convert(boundPrice, 5e18, true); // base->quote
        uint256 expectedUnfilled = 1000e18 - matchedQuoteSpent;

        uint256 traderQuoteBefore = token2.balanceOf(trader1);
        uint256 traderBaseBefore = token1.balanceOf(trader1);

        vm.prank(trader1);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapRouter.MidPathPartialFill.selector, address(token2), address(token1), expectedUnfilled)
        );
        router.swap(path, 1000e18, 0, trader1, false);

        // Full revert must mean full atomicity: the trader's balance of every token in the
        // path is byte-for-byte unchanged -- direct proof nothing was spent, matched, or
        // stranded anywhere, not an assumption resting on "reverts are atomic" alone.
        assertEq(token2.balanceOf(trader1), traderQuoteBefore);
        assertEq(token1.balanceOf(trader1), traderBaseBefore);
        assertEq(token3.balanceOf(trader1), 0);
    }
}
