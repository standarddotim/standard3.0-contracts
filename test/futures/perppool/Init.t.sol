// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";

contract PerpPoolInitTest is PerpPoolUnitSetup {
    function testInitializeAcceptsConfiguredCollateralTokens() public {
        address pool = setUpPool(10, 8000, 1000e18);
        assertTrue(PerpPool(pool).isAcceptedCollateral(address(quoteToken)));
        assertTrue(PerpPool(pool).isAcceptedCollateral(address(altCollateral)));
        assertFalse(PerpPool(pool).isAcceptedCollateral(address(0xDEAD)));
    }

    function testInitializeSetsRiskParams() public {
        address pool = setUpPool(10, 8000, 1000e18);
        assertEq(PerpPool(pool).maxLeverage(), 10);
        assertEq(PerpPool(pool).maxUtilizationBps(), 8000);
        assertEq(PerpPool(pool).minSpotLiquidity(), 1000e18);
    }

    function testReservesStartAtZero() public {
        address pool = setUpPool(10, 8000, 1000e18);
        assertEq(PerpPool(pool).reserveOf(address(quoteToken)), 0);
        assertEq(PerpPool(pool).reserveOf(address(altCollateral)), 0);
    }
}
