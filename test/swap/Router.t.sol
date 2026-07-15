// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

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

        matchingEngine.addPair(address(token1), address(token3), 1e8, 1, address(token1));
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

    function testMidPathLeftoverRefundsEntirePath() public {
        // Shrink the first hop's available liquidity so hop 1 partially fills.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);

        // Same plain-ERC20 substitution as testMultiHopSwapChainsThroughTwoPools above, and
        // for the same reason (avoid Orderbook._sendFunds's unconditional WETH auto-unwrap
        // interacting badly with Pool.swap's ERC20-balance-delta accounting) -- though this
        // test's early-return-on-leftover means hop 2 is never actually reached, so it's a
        // defensive/consistency fix here rather than one this specific test would have hit.
        MockQuote token3 = new MockQuote("Quote2", "QUOTE2");
        token3.mint(lp1, 10000e18);

        matchingEngine.addPair(address(token1), address(token3), 1e8, 1, address(token1));
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

        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn) = router.swap(path, 1000e18, 0, trader1, false);

        assertEq(amountOut, 0);
        assertGt(leftoverIn, 0);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - (1000e18 - leftoverIn));
    }
}
