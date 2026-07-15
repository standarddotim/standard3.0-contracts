// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

contract RemoveLiquidityTest is PoolBaseSetup {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        vm.prank(lp1);
        token1.approve(address(pool), 1000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 1000e18);
        vm.prank(positionManager);
        positionId = pool.addLiquidity(80e8, 120e8, 1000000, 500e18, 500e18, lp1);
    }

    function testPartialRemoveLeavesPositionActive() public {
        uint256 balBefore = token1.balanceOf(lp1);

        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 200e18, 0, lp1);

        IPool.Position memory p = pool.getPosition(positionId);
        assertEq(p.baseAmount, 300e18);
        assertEq(p.quoteAmount, 500e18);
        assertTrue(p.active);
        assertEq(token1.balanceOf(lp1), balBefore + 200e18);
    }

    function testFullRemoveZeroesBalancesButKeepsPositionActive() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 500e18, 500e18, lp1);

        IPool.Position memory p = pool.getPosition(positionId);
        assertEq(p.baseAmount, 0);
        assertEq(p.quoteAmount, 0);
        assertTrue(p.active); // still active -- burn is a separate, explicit PositionManager step (Task 14)
    }

    function testRemoveMoreThanAvailableReverts() public {
        vm.prank(positionManager);
        vm.expectRevert(
            abi.encodeWithSelector(IPool.InsufficientPositionBalance.selector, positionId, 600e18, 500e18)
        );
        pool.removeLiquidity(positionId, 600e18, 0, lp1);
    }
}
