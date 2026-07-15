// contracts/test/swap/AdjustPosition.t.sol
pragma solidity >=0.8;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract AdjustPositionTest is PoolBaseSetup {
    PositionManager pm;
    Pool pmPool;
    MockBase token3;
    MockQuote token4;
    uint256 tokenId;

    function setUp() public override {
        super.setUp();
        // Same reasoning as Task 12's PositionManagerAddLiquidityTest: PoolBaseSetup's
        // token1/token2 pair was already listed with the 0xBEEF placeholder positionManager,
        // so exercising the real PositionManager needs a freshly-listed pair.
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

        vm.prank(lp1);
        token3.approve(address(pmPool), 1000e18);
        vm.prank(lp1);
        token4.approve(address(pmPool), 1000e18);
        vm.prank(lp1);
        tokenId = pm.addLiquidity(address(pmPool), 80e8, 120e8, 1000000, 500e18, 500e18);
    }

    function testAdjustPositionChangesRangeKeepsTokenId() public {
        (, uint256 oldPositionId) = pm.tokenPosition(tokenId);

        vm.prank(lp1);
        token3.approve(address(pm), 200e18);
        vm.prank(lp1);
        token4.approve(address(pm), 200e18);

        vm.prank(lp1);
        pm.adjustPosition(tokenId, 60e8, 140e8, 2000000, 700e18, 700e18);

        assertEq(pm.ownerOf(tokenId), lp1); // same NFT survives
        (, uint256 newPositionId) = pm.tokenPosition(tokenId);

        IPool.Position memory oldP = pmPool.getPosition(oldPositionId);
        assertEq(oldP.baseAmount, 0);
        assertEq(oldP.quoteAmount, 0);

        IPool.Position memory newP = pmPool.getPosition(newPositionId);
        assertEq(newP.minPrice, 60e8);
        assertEq(newP.maxPrice, 140e8);
        assertEq(newP.baseAmount, 700e18);
        assertEq(newP.quoteAmount, 700e18);
    }

    function testAdjustPositionRevertsForNonOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        pm.adjustPosition(tokenId, 60e8, 140e8, 2000000, 700e18, 700e18);
    }

    function testAdjustPositionShrinkRefundsExcessToOwner() public {
        // The old position holds 500e18/500e18 (setUp). Shrinking to 200e18/200e18 must
        // refund the 300e18/300e18 excess to lp1, not strand it inside PositionManager --
        // an earlier draft of adjustPosition only handled growing a position (pulling
        // MORE from the owner when newAmount > old), with no symmetric refund step for the
        // opposite case, silently trapping the excess in the contract forever.
        uint256 lp1BaseBefore = token3.balanceOf(lp1);
        uint256 lp1QuoteBefore = token4.balanceOf(lp1);

        vm.prank(lp1);
        pm.adjustPosition(tokenId, 80e8, 120e8, 1000000, 200e18, 200e18);

        assertEq(token3.balanceOf(lp1), lp1BaseBefore + 300e18);
        assertEq(token4.balanceOf(lp1), lp1QuoteBefore + 300e18);

        (, uint256 newPositionId) = pm.tokenPosition(tokenId);
        IPool.Position memory newP = pmPool.getPosition(newPositionId);
        assertEq(newP.baseAmount, 200e18);
        assertEq(newP.quoteAmount, 200e18);
    }
}
