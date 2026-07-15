// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IPositionManager {
    error NotOwnerOrApproved(uint256 tokenId, address caller);
    error PositionNotEmpty(uint256 tokenId);

    function addLiquidity(
        address pool,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    ) external returns (uint256 tokenId);

    function adjustPosition(
        uint256 tokenId,
        uint256 newMinPrice,
        uint256 newMaxPrice,
        uint32 newSlippageLimit,
        uint256 newBaseAmount,
        uint256 newQuoteAmount
    ) external;

    function removeLiquidity(uint256 tokenId, uint256 baseAmount, uint256 quoteAmount, address recipient) external;

    function collect(uint256 tokenId, address recipient) external returns (uint256 baseFee, uint256 quoteFee);

    function burn(uint256 tokenId) external;

    function tokenPosition(uint256 tokenId) external view returns (address pool, uint256 positionId);
}
