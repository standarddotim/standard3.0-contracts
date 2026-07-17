// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {IPerpPool} from "../../../src/futures/interfaces/IPerpPool.sol";
import {MockToken} from "../../../src/mock/MockToken.sol";

interface IMatchingEngineMock {
    function mktPrice(address base, address quote) external view returns (uint256);
    function getPair(address base, address quote) external view returns (address);
}

// Minimal mock standing in for MatchingEngine's price-lookup surface, plus a fake spot pool
// whose token balance PerpPool reads for the spot-liquidity gate.
contract MockMatchingEngine {
    mapping(bytes32 => uint256) public prices;
    mapping(bytes32 => address) public pairs;

    function setPrice(address base, address quote, uint256 price) external {
        prices[keccak256(abi.encodePacked(base, quote))] = price;
    }

    function mktPrice(address base, address quote) external view returns (uint256) {
        return prices[keccak256(abi.encodePacked(base, quote))];
    }

    function setPair(address base, address quote, address book) external {
        pairs[keccak256(abi.encodePacked(base, quote))] = book;
    }

    function getPair(address base, address quote) external view returns (address) {
        return pairs[keccak256(abi.encodePacked(base, quote))];
    }
}

contract MockOrderbook {
    address public pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool() external view returns (address) {
        return pool;
    }
}

contract PerpPoolOpenPositionTest is PerpPoolUnitSetup {
    PerpPool pool;
    MockMatchingEngine mockEngine;
    MockOrderbook mockOrderbook;
    MockToken spotLiquidityHolder;

    function setUp() public {
        // maxUtilizationBps is set to 80000 (800%), not the "production-flavored" 8000 (80%)
        // used elsewhere (e.g. Init.t.sol). Phase 1's _totalReserveInQuote() treats a trader's
        // own just-deposited margin as pool reserve (see its doc comment), so a fresh pool's
        // very first leveraged open is self-referential: notional = margin*leverage while
        // cap = (margin)*maxUtilizationBps/10000, and no leverage>=1 can ever pass an 80% cap
        // when the position's own margin is its only backing. 800% keeps leverage-5 opens
        // (as used below) comfortably under cap while still leaving Step 3's cap formula
        // breachable by a second, sufficiently large/leveraged position -- see the OI-cap test.
        address poolAddr = setUpPool(10, 80000, 1000e18);
        pool = PerpPool(poolAddr);

        // Redeploy setUpPool's matchingEngine as a real mock at the address PerpPool already
        // points to is not possible post-deploy, so this task's tests use vm.etch to install
        // real mock bytecode at the fixed `matchingEngine` address PerpPoolUnitSetup already
        // wired into the pool at construction time.
        MockMatchingEngine deployed = new MockMatchingEngine();
        vm.etch(matchingEngine, address(deployed).code);

        // fake spot pool holding quote liquidity, registered behind a fake orderbook
        spotLiquidityHolder = quoteToken;
        MockOrderbook ob = new MockOrderbook(address(this));
        MockMatchingEngine(matchingEngine).setPair(address(baseToken), address(quoteToken), address(ob));

        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 100e8); // $100
        quoteToken.mint(address(this), 5000e18); // this test contract IS the fake spot pool

        quoteToken.mint(trader1, 20000e18);
        vm.prank(trader1);
        quoteToken.approve(address(pool), 20000e18);
    }

    function testOpenPositionTransfersRealCollateral() public {
        uint256 poolBalBefore = quoteToken.balanceOf(address(pool));
        uint256 traderBalBefore = quoteToken.balanceOf(trader1);

        vm.prank(perpEngine);
        pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);

        assertEq(quoteToken.balanceOf(address(pool)), poolBalBefore + 100e18);
        assertEq(quoteToken.balanceOf(trader1), traderBalBefore - 100e18);
        assertEq(pool.reserveOf(address(quoteToken)), 100e18);
    }

    function testOpenPositionSizesNotionalFromMarginTimesLeverage() public {
        vm.prank(perpEngine);
        uint256 id = pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);

        IPerpPool.Position memory p = pool.getPosition(id);
        assertEq(p.margin, 100e18);
        assertEq(p.leverage, 5);
        assertEq(p.entryPrice, 100e8);
        assertEq(p.owner, trader1);
        assertTrue(p.isLong);
        assertEq(pool.longOpenInterest(), 100e18 * 5);
    }

    function testOpenPositionRevertsForUnacceptedCollateral() public {
        MockToken rogue = new MockToken("Rogue", "RGE", 18);
        rogue.mint(trader1, 100e18);
        vm.prank(trader1);
        rogue.approve(address(pool), 100e18);

        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(rogue), 100e18, 5, trader1);
    }

    function testOpenPositionRevertsAboveMaxLeverage() public {
        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 100e18, 11, trader1); // pool max is 10
    }

    function testOpenPositionRevertsWhenNotCalledByPerpEngine() public {
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);
    }

    function testOpenPositionRevertsWhenSpotLiquidityBelowMinimum() public {
        // drain the fake spot pool below the 1000e18 minSpotLiquidity threshold
        quoteToken.transfer(address(0xdead), quoteToken.balanceOf(address(this)));

        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);
    }

    function testOpenPositionRevertsWhenOpenInterestCapExceeded() public {
        // reserve is 0 until this trader deposits; cap = reserve * maxUtilizationBps / 10000, so a
        // fresh pool with no prior reserve can't support any leveraged notional on the first open
        // beyond its own just-deposited margin. Use a second, well-funded trader to seed the
        // reserve first, at 6x leverage (comfortably under the pool's 8x cap multiplier so this
        // seed itself succeeds with headroom -- cap=80000e18, OI=60000e18 after this call).
        quoteToken.mint(trader2, 10000e18);
        vm.prank(trader2);
        quoteToken.approve(address(pool), 10000e18);
        vm.prank(perpEngine);
        pool.openPosition(true, address(quoteToken), 10000e18, 6, trader2); // seeds reserve=10000e18, OI=60000e18

        // now attempt a large, max-leverage (10x) position whose notional pushes longOpenInterest
        // past cap = (reserve_after) * maxUtilizationBps / 10000 = 25000e18 * 8 = 200000e18:
        // sideOI(60000e18) + notional(15000e18*10=150000e18) = 210000e18 > 200000e18 cap.
        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 15000e18, 10, trader1);
    }
}
