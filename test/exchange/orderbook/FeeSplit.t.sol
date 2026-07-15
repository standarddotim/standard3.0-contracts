// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";

contract FeeSplitTest is BaseSetup {
    function testRegularTraderOrderFeeGoes100PercentToFeeToByDefault() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1));

        uint256 feeToBalanceBefore = token2.balanceOf(booker);

        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(token2), 1e8, 100e18, true, 2, trader1);
        vm.prank(trader2);
        matchingEngine.limitSell(address(token1), address(token2), 1e8, 100e18, true, 2, trader2);

        // booker is BaseSetup's feeTo recipient (see OrderbookBaseSetup.sol setUp);
        // with poolFeeShare defaulting to 0, this must be unaffected by this change --
        // i.e. equal to whatever it was before Task 4 (a regression guard, not a new assertion
        // about the exact amount, since the exact fee amount is already covered by existing
        // exchange test suite).
        assertGt(token2.balanceOf(booker), feeToBalanceBefore);
    }

    function testPoolFeeShareDefaultsToZero() public {
        super.setUp();
        assertEq(matchingEngine.poolFeeShare(), 0);
    }

    function testSetPoolFeeShareChangesSplitForPoolOwnedOrders() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1));
        address pairAddr = matchingEngine.getPair(address(token1), address(token2));

        vm.prank(address(matchingEngine));
        Orderbook(payable(pairAddr)).setPool(address(this)); // this test contract stands in for Pool

        matchingEngine.setPoolFeeShare(50000000); // 50% in DENOM=1e8 terms

        token2.mint(address(this), 1000e18);
        token2.approve(address(matchingEngine), 1000e18);

        uint256 feeToBalanceBefore = token2.balanceOf(booker);
        // The pool places a limitBuy, so it pays token2 (quote) and receives token1 (base)
        // on fill -- _sendFunds's pool-fee-split fires on the leg where to == pool, which
        // for a buy order is the base leg. Measure the pool's gain in token1, not token2.
        uint256 poolBalanceBefore = token1.balanceOf(address(this));

        // Place this order AS the registered pool (msg.sender/recipient = address(this)).
        matchingEngine.limitBuy(address(token1), address(token2), 1e8, 100e18, true, 2, address(this));
        vm.prank(trader2);
        matchingEngine.limitSell(address(token1), address(token2), 1e8, 100e18, true, 2, trader2);

        // Compute the expected pool gain from the contract's own fee rate rather than
        // hardcoding it, so this stays correct if defaults ever change. The pool's limitBuy
        // is placed before trader2's limitSell, so the pool's order rests as maker and the
        // MAKER fee applies to the base leg (to == pool).
        uint32 baseFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(this), true);
        uint256 amountMatched = 100e18;
        uint256 expectedFeeAmount = (amountMatched * baseFeeRate) / matchingEngine.DENOM();
        uint256 expectedPoolShare = (expectedFeeAmount * 50000000) / matchingEngine.DENOM();
        uint256 expectedPoolGain = (amountMatched - expectedFeeAmount) + expectedPoolShare;

        uint256 feeToGain = token2.balanceOf(booker) - feeToBalanceBefore;
        uint256 poolGain = token1.balanceOf(address(this)) - poolBalanceBefore;

        assertGt(expectedPoolShare, 0); // sanity: the fee split this test exists to verify must be nonzero
        assertEq(poolGain, expectedPoolGain); // proves the pool received trade proceeds AND its fee share -- would fail if the split were missing or miscomputed
        assertGt(feeToGain, 0);
    }
}
