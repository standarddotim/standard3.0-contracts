// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract PositionManagerAddLiquidityTest is PoolBaseSetup {
    PositionManager pm;
    Pool pmPool; // a *second* pair's pool, listed after positionManager is wired up --
    // PoolBaseSetup.setUp() already listed the token1/token2 pair with the 0xBEEF
    // placeholder positionManager (Task 6), and Pool.initialize (Task 2) captures
    // positionManager at creation time with no setter afterward, so exercising the real
    // PositionManager requires a freshly-listed pair, not reusing token1/token2.
    MockBase token3;
    MockQuote token4;

    function setUp() public override {
        super.setUp();

        pm = new PositionManager();
        pm.initialize("Standard Swap Positions", "STDPOS");
        pm.setPoolFactory(address(poolFactory));
        poolFactory.setPositionManager(address(pm));

        token3 = new MockBase("Base2", "BASE2");
        token4 = new MockQuote("Quote2", "QUOTE2");
        token3.mint(lp1, 10000e18);
        token4.mint(lp1, 10000e18);

        matchingEngine.addPair(address(token3), address(token4), 100e8, 1, address(token3));
        pmPool = Pool(poolFactory.getPool(address(token3), address(token4)));
    }

    function testAddLiquidityMintsNftToOwner() public {
        vm.prank(lp1);
        token3.approve(address(pmPool), 1000e18);
        vm.prank(lp1);
        token4.approve(address(pmPool), 1000e18);

        vm.prank(lp1);
        uint256 tokenId = pm.addLiquidity(address(pmPool), 80e8, 120e8, 1000000, 500e18, 500e18);

        assertEq(pm.ownerOf(tokenId), lp1);
        (address poolAddr, uint256 positionId) = pm.tokenPosition(tokenId);
        assertEq(poolAddr, address(pmPool));
        IPool.Position memory p = pmPool.getPosition(positionId);
        assertEq(p.baseAmount, 500e18);
    }
}
