// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {IPerpPool} from "../interfaces/IPerpPool.sol";
import {Initializable} from "../../security/Initializable.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

interface IWETHMinimal {
    function WETH() external view returns (address);

    function transfer(address to, uint256 value) external returns (bool);

    function withdraw(uint256) external;
}

contract PerpPool is IPerpPool, Initializable {
    // Pool Struct
    struct Pool {
        uint256 id;
        address base;
        address quote;
        address collateral;
        address engine;
        address perp;
    }

    Pool private pool;

    uint256 collateralOne;

    error InvalidDecimals(uint8 base, uint8 quote);
    error InvalidAccess(address sender, address allowed);
    error PriceIsZero(uint256 price);

    function initialize(uint256 id_, address base_, address quote_, address collateral_, address engine_, address perp_)
        external
        initializer
    {
        uint8 baseD = TransferHelper.decimals(base_);
        uint8 quoteD = TransferHelper.decimals(quote_);
        uint8 collD = TransferHelper.decimals(collateral_);
        if (baseD > 18 || quoteD > 18) {
            revert InvalidDecimals(baseD, quoteD);
        }
        collateralOne = 10 ** (collD);
        pool = Pool(id_, base_, quote_, collateral_, engine_, perp_);
    }

    modifier onlyEngine() {
        if (msg.sender != pool.engine) {
            revert InvalidAccess(msg.sender, pool.engine);
        }
        _;
    }

    function placeShort(address owner, uint256 price, uint256 amount, uint32 leverage, bool autoUpdate)
        external
        onlyEngine
        returns (uint32 id)
    {
        revert("PerpPool: not yet implemented, see Task 2");
    }

    function placeLong(address owner, uint256 price, uint256 amount, uint32 leverage, bool autoUpdate)
        external
        onlyEngine
        returns (uint32 id)
    {
        revert("PerpPool: not yet implemented, see Task 2");
    }

    function closePosition(bool isLong, uint256 positionId, address owner)
        external
        onlyEngine
        returns (uint256 remaining)
    {
        revert("PerpPool: not yet implemented, see Task 2");
    }

    function liquidate(bool isLong, uint32 positionId) public onlyEngine returns (address owner) {
        revert("PerpPool: not yet implemented, see Task 2");
    }

    function batchLiquidate(bool[] memory isLong, uint32[] memory positionId)
        external
        onlyEngine
        returns (address owner)
    {
        for (uint256 i = 0; i < positionId.length; i++) {
            liquidate(isLong[i], positionId[i]);
        }
    }

    function _sendFunds(address token, address to, uint256 amount) internal returns (bool) {
        address weth = IWETHMinimal(pool.engine).WETH();
        if (token == weth) {
            IWETHMinimal(weth).withdraw(amount);
            return payable(to).send(amount);
        } else {
            TransferHelper.safeTransfer(token, to, amount);
            return true;
        }
    }

    function _absdiff(uint8 a, uint8 b) internal pure returns (uint8, bool) {
        return (a > b ? a - b : b - a, a > b);
    }

    receive() external payable {
        assert(msg.sender == IWETHMinimal(pool.engine).WETH());
    }

    function placeShort(address owner, uint256 price, uint256 amount, bool autoUpdate)
        external
        override
        returns (uint256 id)
    {}

    function placeLong(address owner, uint256 price, uint256 amount, bool autoUpdate)
        external
        override
        returns (uint256 id)
    {}

    function openPosition(bool isLong, uint256 price, uint256 amount, address owner)
        external
        override
        returns (uint256 id)
    {}
}
