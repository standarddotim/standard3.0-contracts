// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {WETH9} from "../../src/mock/WETH9.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {PoolFactory} from "../../src/swap/PoolFactory.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {Utils} from "../utils/Utils.sol";

contract PoolBaseSetup is Test {
    Utils public utils;
    MatchingEngine public matchingEngine;
    WETH9 public weth;
    OrderbookFactory public orderbookFactory;
    PoolFactory public poolFactory;
    MockBase public token1; // base
    MockQuote public token2; // quote
    Orderbook public book;
    Pool public pool;

    address payable[] public users;
    address public trader1;
    address public trader2;
    address public lp1;
    address public lp2;
    address public booker;
    address public positionManager;

    function setUp() public virtual {
        utils = new Utils();
        users = utils.createUsers(5);
        trader1 = users[0];
        trader2 = users[1];
        lp1 = users[2];
        lp2 = users[3];
        booker = users[4];
        positionManager = address(0xBEEF); // placeholder caller until Task 12 -- production
        // deployments set this to the real PositionManager contract via
        // poolFactory.setPositionManager, matching how Task 5's PoolCreationTest does it.

        token1 = new MockBase("Base", "BASE");
        token2 = new MockQuote("Quote", "QUOTE");
        weth = new WETH9();

        token1.mint(trader1, 10000000e18);
        token2.mint(trader1, 10000000e18);
        token1.mint(trader2, 10000000e18);
        token2.mint(trader2, 10000000e18);
        token1.mint(lp1, 10000000e18);
        token2.mint(lp1, 10000000e18);
        token1.mint(lp2, 10000000e18);
        token2.mint(lp2, 10000000e18);

        matchingEngine = new MatchingEngine();
        orderbookFactory = new OrderbookFactory();
        orderbookFactory.initialize(address(matchingEngine));
        matchingEngine.initialize(address(orderbookFactory), address(booker), address(weth));

        poolFactory = new PoolFactory();
        poolFactory.initialize(address(matchingEngine));
        poolFactory.setPositionManager(positionManager);
        matchingEngine.setPoolFactory(address(poolFactory));

        matchingEngine.setDefaultSpread(2000000, 2000000, true);
        matchingEngine.setDefaultSpread(2000000, 2000000, false);
        matchingEngine.setDefaultFee(true, 100000);
        matchingEngine.setDefaultFee(false, 100000);

        vm.prank(trader1);
        token1.approve(address(matchingEngine), 10000000e18);
        vm.prank(trader1);
        token2.approve(address(matchingEngine), 10000000e18);
        vm.prank(trader2);
        token1.approve(address(matchingEngine), 10000000e18);
        vm.prank(trader2);
        token2.approve(address(matchingEngine), 10000000e18);

        matchingEngine.addPair(address(token1), address(token2), 100e8, 0, address(token1));
        address bookAddr = matchingEngine.getPair(address(token1), address(token2));
        book = Orderbook(payable(bookAddr));
        address poolAddr = poolFactory.getPool(address(token1), address(token2));
        pool = Pool(poolAddr);
    }
}
