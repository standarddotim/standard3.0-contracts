// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

interface IPerpEngine {
    function setFeeTo(address feeTo_) external returns (bool success);

    function setStablecoin(address token, bool accepted) external;

    function addPool(
        address base,
        address quote,
        address[] calldata collateralTokens,
        uint32 maxLeverage,
        uint32 maxUtilizationBps,
        uint256 minSpotLiquidity
    ) external returns (address pool);

    // Passthrough for PerpPool.seedReserve, which is onlyPerpEngine-gated so production
    // seeding must route through here. Gated by MARKET_MAKER_ROLE; the caller (market maker)
    // is the funder and must have approved the POOL (not this engine) beforehand.
    function seedPool(address pool, address token, uint256 amount) external returns (bool);

    function long(address pool, address collateralToken, uint256 collateralAmount, uint32 leverage)
        external
        returns (uint256 positionId);

    function short(address pool, address collateralToken, uint256 collateralAmount, uint32 leverage)
        external
        returns (uint256 positionId);

    function closePosition(address pool, uint256 positionId) external returns (int256 pnl, uint256 payout);

    function liquidate(address pool, uint256 positionId) external returns (uint256 feeFund, uint256 poolFund);

    function getPool(address base, address quote) external view returns (address pool);
}
