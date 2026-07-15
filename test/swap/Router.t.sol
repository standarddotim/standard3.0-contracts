// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";

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
}
