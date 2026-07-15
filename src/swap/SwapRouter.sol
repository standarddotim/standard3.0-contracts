// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IPoolFactory} from "./interfaces/IPoolFactory.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

contract SwapRouter is ISwapRouter {
    address public immutable poolFactory;

    constructor(address poolFactory_) {
        poolFactory = poolFactory_;
    }

    function swap(
        address[] calldata path,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bool restLeftoverOnFinalHop
    ) external returns (uint256 amountOut, uint256 leftoverIn) {
        TransferHelper.safeTransferFrom(path[0], msg.sender, address(this), amountIn);

        uint256 currentAmountIn = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            bool isFinalHop = i == path.length - 2;

            (currentAmountIn, leftoverIn) = _executeHop(
                path[i],
                path[i + 1],
                currentAmountIn,
                isFinalHop ? recipient : address(this),
                isFinalHop && restLeftoverOnFinalHop
            );

            if (!isFinalHop && leftoverIn > 0) {
                // Mid-path leftover has no natural single order to become (design doc §4.4) --
                // refund the whole path immediately rather than continuing with a partial amount.
                TransferHelper.safeTransfer(path[i], msg.sender, leftoverIn);
                return (0, leftoverIn);
            }
        }

        amountOut = currentAmountIn;

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(minAmountOut, amountOut);
        }
    }

    function _executeHop(
        address tokenIn,
        address tokenOut,
        uint256 amountIn_,
        address hopRecipient,
        bool restLeftoverOnHop
    ) private returns (uint256 hopAmountOut, uint256 hopLeftover) {
        address pool = IPoolFactory(poolFactory).getPool(tokenIn, tokenOut);
        if (pool == address(0)) {
            pool = IPoolFactory(poolFactory).getPool(tokenOut, tokenIn);
        }
        if (pool == address(0)) {
            revert PoolDoesNotExist(tokenIn, tokenOut);
        }

        (address poolBase,) = IPool(pool).getBaseQuote();
        bool quoteToBase = poolBase != tokenIn; // tokenIn is quote if it's not the pool's base

        TransferHelper.safeApprove(tokenIn, pool, amountIn_);

        (hopAmountOut, hopLeftover) = IPool(pool).swap(amountIn_, quoteToBase, hopRecipient, restLeftoverOnHop);
    }
}
