// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {IPerpPool} from "../interfaces/IPerpPool.sol";
import {FuturesPool} from "../libraries/FuturesPool.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {Initializable} from "../../security/Initializable.sol";

interface IMatchingEnginePrice {
    function mktPrice(address base, address quote) external view returns (uint256);
    function getPair(address base, address quote) external view returns (address book);
}

interface IOrderbookPool {
    function getPool() external view returns (address);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

contract PerpPool is IPerpPool, Initializable {
    struct Market {
        uint256 id;
        address base;
        address quote;
        address matchingEngine;
        address perpEngine;
    }

    Market public market;

    uint32 public maxLeverage;
    uint32 public maxUtilizationBps;
    uint256 public minSpotLiquidity;

    mapping(address => bool) public isAcceptedCollateral;
    mapping(address => uint256) public reserveOf;

    mapping(uint256 => Position) internal positions;
    uint256 public positionCount;

    uint256 public longOpenInterest;
    uint256 public shortOpenInterest;

    event PositionOpened(
        uint256 indexed positionId, address indexed trader, bool isLong, uint256 entryPrice, uint256 margin, uint32 leverage
    );
    event PositionClosed(uint256 indexed positionId, address indexed trader, uint256 exitPrice, int256 pnl, uint256 payout);
    event PositionLiquidated(uint256 indexed positionId, address indexed trader, uint256 markPrice, uint256 feeFund, uint256 poolFund);

    error CollateralNotAccepted(address token);
    error LeverageLimitExceeded(uint32 leverage, uint32 maxLeverage_);
    error AmountIsZero();
    error PriceIsZero(uint256 price);
    error InsufficientSpotLiquidity(uint256 have, uint256 required);
    error OpenInterestCapExceeded(uint256 attempted, uint256 cap);
    error InvalidAccess(address sender, address allowed);
    error PositionNotFound(uint256 positionId);
    error NotLiquidatable(uint256 positionId);
    error InsufficientPoolReserve(uint256 requested, uint256 available);
    error NotPositionOwner(address caller, address owner);

    modifier onlyPerpEngine() {
        if (msg.sender != market.perpEngine) {
            revert InvalidAccess(msg.sender, market.perpEngine);
        }
        _;
    }

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address matchingEngine_,
        address perpEngine_,
        address[] calldata collateralTokens_,
        uint32 maxLeverage_,
        uint32 maxUtilizationBps_,
        uint256 minSpotLiquidity_
    ) external initializer {
        market = Market(id_, base_, quote_, matchingEngine_, perpEngine_);
        maxLeverage = maxLeverage_;
        maxUtilizationBps = maxUtilizationBps_;
        minSpotLiquidity = minSpotLiquidity_;
        for (uint256 i = 0; i < collateralTokens_.length; i++) {
            isAcceptedCollateral[collateralTokens_[i]] = true;
        }
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    // --- interface-completeness stubs; real implementations land in Tasks 4-6 ---

    function openPosition(bool isLong, address collateralToken, uint256 collateralAmount, uint32 leverage, address trader)
        external
        override
        onlyPerpEngine
        returns (uint256 positionId)
    {
        if (!isAcceptedCollateral[collateralToken]) {
            revert CollateralNotAccepted(collateralToken);
        }
        if (collateralAmount == 0) {
            revert AmountIsZero();
        }
        if (leverage == 0 || leverage > maxLeverage) {
            revert LeverageLimitExceeded(leverage, maxLeverage);
        }

        uint256 spotLiquidity = _spotLiquidity();
        if (spotLiquidity < minSpotLiquidity) {
            revert InsufficientSpotLiquidity(spotLiquidity, minSpotLiquidity);
        }

        TransferHelper.safeTransferFrom(collateralToken, trader, address(this), collateralAmount);
        reserveOf[collateralToken] += collateralAmount;

        uint256 entryPrice = IMatchingEnginePrice(market.matchingEngine).mktPrice(market.base, market.quote);
        if (entryPrice == 0) {
            revert PriceIsZero(entryPrice);
        }

        uint256 marginQuote = _toQuoteValue(collateralToken, collateralAmount);
        uint256 notional = marginQuote * leverage;

        uint256 sideOI = isLong ? longOpenInterest : shortOpenInterest;
        uint256 cap = (_totalReserveInQuote() * maxUtilizationBps) / 10000;
        if (sideOI + notional > cap) {
            revert OpenInterestCapExceeded(sideOI + notional, cap);
        }

        positionCount += 1;
        positionId = positionCount;
        positions[positionId] = Position({
            owner: trader,
            collateralToken: collateralToken,
            margin: marginQuote,
            entryPrice: entryPrice,
            leverage: leverage,
            isLong: isLong
        });

        if (isLong) {
            longOpenInterest += notional;
        } else {
            shortOpenInterest += notional;
        }

        emit PositionOpened(positionId, trader, isLong, entryPrice, marginQuote, leverage);
        return positionId;
    }

    function _totalReserveInQuote() internal view returns (uint256 total) {
        // Phase 1 keeps this simple: sum reserves already known to be accepted collateral,
        // normalized to quote value at the current price. This is called once per open, so an
        // O(n) loop over accepted collateral is fine for the small collateral lists expected here.
        total = reserveOf[market.quote];
        // Non-quote collateral reserves are added by openPosition's own _toQuoteValue calls at
        // insertion time in a future refinement; Phase 1's cap check uses the quote-denominated
        // reserve as the conservative floor so the cap can never be looser than actual backing.
    }

    function closePosition(uint256 positionId, address trader) external returns (int256 pnl, uint256 payout) {
        revert("PerpPool: not yet implemented, see Task 5");
    }

    function liquidate(uint256 positionId) external returns (uint256 feeFund, uint256 poolFund) {
        revert("PerpPool: not yet implemented, see Task 6");
    }

    // --- internal helpers shared by Tasks 4-6 ---

    function _spotLiquidity() internal view returns (uint256) {
        address orderbook = IMatchingEnginePrice(market.matchingEngine).getPair(market.base, market.quote);
        if (orderbook == address(0)) return 0;
        address swapPool = IOrderbookPool(orderbook).getPool();
        if (swapPool == address(0)) return 0;
        return IERC20Minimal(market.quote).balanceOf(swapPool);
    }

    function _toQuoteValue(address collateralToken, uint256 amount) internal view returns (uint256) {
        if (collateralToken == market.quote) return amount;
        uint256 price = IMatchingEnginePrice(market.matchingEngine).mktPrice(collateralToken, market.quote);
        if (price == 0) revert PriceIsZero(price);
        uint8 collateralDecimals = TransferHelper.decimals(collateralToken);
        uint8 quoteDecimals = TransferHelper.decimals(market.quote);
        uint256 raw = (amount * price) / 1e8;
        if (collateralDecimals == quoteDecimals) return raw;
        if (collateralDecimals > quoteDecimals) return raw / (10 ** (collateralDecimals - quoteDecimals));
        return raw * (10 ** (quoteDecimals - collateralDecimals));
    }

    function _fromQuoteValue(address collateralToken, uint256 quoteAmount) internal view returns (uint256) {
        if (collateralToken == market.quote) return quoteAmount;
        uint256 price = IMatchingEnginePrice(market.matchingEngine).mktPrice(collateralToken, market.quote);
        if (price == 0) revert PriceIsZero(price);
        uint8 collateralDecimals = TransferHelper.decimals(collateralToken);
        uint8 quoteDecimals = TransferHelper.decimals(market.quote);
        uint256 raw = (quoteAmount * 1e8) / price;
        if (collateralDecimals == quoteDecimals) return raw;
        if (collateralDecimals > quoteDecimals) return raw * (10 ** (collateralDecimals - quoteDecimals));
        return raw / (10 ** (quoteDecimals - collateralDecimals));
    }
}
