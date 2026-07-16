// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IPool {
    struct Position {
        uint256 minPrice;
        uint256 maxPrice;
        uint32 slippageLimit;
        uint256 baseAmount;
        uint256 quoteAmount;
        uint256 feeOwedBase;
        uint256 feeOwedQuote;
        bool active;
    }

    event LiquidityAdded(
        uint256 indexed positionId,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    );
    event LiquidityRemoved(uint256 indexed positionId, uint256 baseAmount, uint256 quoteAmount);
    event FeeCollected(uint256 indexed positionId, uint256 baseFee, uint256 quoteFee);
    event Swap(
        address indexed recipient,
        bool quoteToBase,
        uint256 amountIn,
        uint256 amountOut,
        uint256 leftoverIn
    );
    event PositionDeactivated(uint256 indexed positionId);

    error OnlyPositionManager(address caller, address positionManager);
    error PositionDoesNotExist(uint256 positionId);
    error PositionNotEmpty(uint256 positionId);
    error NoLiquidityInRange(uint256 marketPrice);
    error TooManyPositionsInRange(uint32 cap);
    error InsufficientPositionBalance(uint256 positionId, uint256 requested, uint256 available);

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address orderbook_,
        address engine_,
        address positionManager_
    ) external;

    function addLiquidity(
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount,
        address payer
    ) external returns (uint256 positionId);

    function removeLiquidity(uint256 positionId, uint256 baseAmount, uint256 quoteAmount, address recipient)
        external;

    function collect(uint256 positionId, address recipient) external returns (uint256 baseFee, uint256 quoteFee);

    function swap(uint256 amountIn, bool quoteToBase, address recipient, bool restLeftoverOnFinalHop)
        external
        returns (uint256 amountOut, uint256 leftoverIn);

    function creditFee(uint256[] calldata positionIds, uint256[] calldata shares, bool isBaseFee, uint256 totalFee)
        external;

    function getPosition(uint256 positionId) external view returns (Position memory);

    function getBaseQuote() external view returns (address base, address quote);

    function activePositionsLength() external view returns (uint256);
}
