// contracts/test/exchange/orderbook/PoolAwareness.t.sol
pragma solidity >=0.8;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";

contract PoolAwarenessTest is BaseSetup {
    function testPoolDefaultsToZeroAddress() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1));
        address pairAddr = matchingEngine.getPair(address(token1), address(token2));
        assertEq(Orderbook(payable(pairAddr)).getPool(), address(0));
    }

    function testSetPoolOnlyCallableByEngine() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1));
        address pairAddr = matchingEngine.getPair(address(token1), address(token2));

        vm.prank(trader1);
        vm.expectRevert();
        Orderbook(payable(pairAddr)).setPool(address(0xCAFE));
    }

    function testSetPoolByEngineSucceeds() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1));
        address pairAddr = matchingEngine.getPair(address(token1), address(token2));

        // matchingEngine is the pair's `engine` (Orderbook.initialize's engine_ arg),
        // so pranking as matchingEngine satisfies Orderbook's onlyEngine-style check.
        vm.prank(address(matchingEngine));
        Orderbook(payable(pairAddr)).setPool(address(0xCAFE));
        assertEq(Orderbook(payable(pairAddr)).getPool(), address(0xCAFE));
    }
}
