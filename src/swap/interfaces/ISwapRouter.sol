// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface ISwapRouter {
    error PoolDoesNotExist(address tokenIn, address tokenOut);
    error SlippageExceeded(uint256 requested, uint256 actual);
    error MidPathPartialFill(address tokenIn, address tokenOut, uint256 unfilledAmount);

    function swap(
        address[] calldata path,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bool restLeftoverOnFinalHop
    ) external returns (uint256 amountOut, uint256 leftoverIn);
}
