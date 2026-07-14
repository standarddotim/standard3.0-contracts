// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {Initializable} from "../security/Initializable.sol";

contract Pool is IPool, Initializable {
    uint256 public id;
    address public base;
    address public quote;
    address public orderbook;
    address public engine;
    address public positionManager;
    uint64 public decDiff;
    bool public baseBquote;

    uint256 public nextPositionId;
    mapping(uint256 => Position) public positions;
    uint32 public constant MAX_POSITIONS_PER_SWAP = 20;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) {
            revert OnlyPositionManager(msg.sender, positionManager);
        }
        _;
    }

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address orderbook_,
        address engine_,
        address positionManager_
    ) external initializer {
        id = id_;
        base = base_;
        quote = quote_;
        orderbook = orderbook_;
        engine = engine_;
        positionManager = positionManager_;

        uint8 baseD = TransferHelper.decimals(base_);
        uint8 quoteD = TransferHelper.decimals(quote_);
        (uint8 diff, bool baseBquote_) = _absdiff(baseD, quoteD);
        decDiff = uint64(10 ** diff);
        baseBquote = baseBquote_;
    }

    function addLiquidity(
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount,
        address payer
    ) external onlyPositionManager returns (uint256 positionId) {
        if (baseAmount > 0) {
            TransferHelper.safeTransferFrom(base, payer, address(this), baseAmount);
        }
        if (quoteAmount > 0) {
            TransferHelper.safeTransferFrom(quote, payer, address(this), quoteAmount);
        }

        positionId = ++nextPositionId;
        positions[positionId] = Position({
            minPrice: minPrice,
            maxPrice: maxPrice,
            slippageLimit: slippageLimit,
            baseAmount: baseAmount,
            quoteAmount: quoteAmount,
            feeOwedBase: 0,
            feeOwedQuote: 0,
            active: true
        });

        emit LiquidityAdded(positionId, minPrice, maxPrice, slippageLimit, baseAmount, quoteAmount);
    }

    function removeLiquidity(uint256 positionId, uint256 baseAmount, uint256 quoteAmount, address recipient)
        external
        onlyPositionManager
    {
        Position storage p = positions[positionId];
        if (!p.active) revert PositionDoesNotExist(positionId);
        if (baseAmount > p.baseAmount) {
            revert InsufficientPositionBalance(positionId, baseAmount, p.baseAmount);
        }
        if (quoteAmount > p.quoteAmount) {
            revert InsufficientPositionBalance(positionId, quoteAmount, p.quoteAmount);
        }

        p.baseAmount -= baseAmount;
        p.quoteAmount -= quoteAmount;

        if (baseAmount > 0) TransferHelper.safeTransfer(base, recipient, baseAmount);
        if (quoteAmount > 0) TransferHelper.safeTransfer(quote, recipient, quoteAmount);

        emit LiquidityRemoved(positionId, baseAmount, quoteAmount);
    }

    function collect(uint256 positionId, address recipient)
        external
        onlyPositionManager
        returns (uint256 baseFee, uint256 quoteFee)
    {
        Position storage p = positions[positionId];
        if (!p.active) revert PositionDoesNotExist(positionId);

        baseFee = p.feeOwedBase;
        quoteFee = p.feeOwedQuote;
        p.feeOwedBase = 0;
        p.feeOwedQuote = 0;

        if (baseFee > 0) TransferHelper.safeTransfer(base, recipient, baseFee);
        if (quoteFee > 0) TransferHelper.safeTransfer(quote, recipient, quoteFee);

        emit FeeCollected(positionId, baseFee, quoteFee);
    }

    function creditFee(uint256[] calldata positionIds, uint256[] calldata shares, bool isBaseFee, uint256 totalFee)
        external
    {
        // Called by this same Pool contract internally from `swap` (Task 11) --
        // kept as a separate external-but-self-only-callable function so `swap`'s
        // fee-crediting logic is unit-testable in isolation from full swap execution.
        if (msg.sender != address(this)) revert OnlyPositionManager(msg.sender, address(this));
        uint256 sharesSum;
        for (uint256 i = 0; i < shares.length; i++) {
            sharesSum += shares[i];
        }
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 owed = sharesSum == 0 ? 0 : (totalFee * shares[i]) / sharesSum;
            if (isBaseFee) {
                positions[positionIds[i]].feeOwedBase += owed;
            } else {
                positions[positionIds[i]].feeOwedQuote += owed;
            }
        }
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getBaseQuote() external view returns (address, address) {
        return (base, quote);
    }

    function swap(uint256 amountIn, bool quoteToBase, address recipient, bool restLeftoverOnFinalHop)
        external
        returns (uint256 amountOut, uint256 leftoverIn)
    {
        revert("swap not yet implemented");
    }

    function _absdiff(uint8 a, uint8 b) internal pure returns (uint8, bool) {
        return (a > b ? a - b : b - a, a > b);
    }
}
