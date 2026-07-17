// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

contract PositionManager is IPositionManager, ERC721Upgradeable, OwnableUpgradeable {
    struct TokenPosition {
        address pool;
        uint256 positionId;
    }

    mapping(uint256 => TokenPosition) internal _tokenPositions;
    uint256 public nextTokenId;
    address public poolFactory;

    modifier onlyOwnerOrApproved(uint256 tokenId) {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) {
            revert NotOwnerOrApproved(tokenId, msg.sender);
        }
        _;
    }

    function initialize(string memory name_, string memory symbol_) external initializer {
        __ERC721_init(name_, symbol_);
        __Ownable_init(msg.sender);
    }

    function setPoolFactory(address poolFactory_) external onlyOwner {
        poolFactory = poolFactory_;
    }

    function addLiquidity(
        address pool,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    ) external returns (uint256 tokenId) {
        uint256 positionId =
            IPool(pool).addLiquidity(minPrice, maxPrice, slippageLimit, baseAmount, quoteAmount, msg.sender);

        tokenId = ++nextTokenId;
        _tokenPositions[tokenId] = TokenPosition({pool: pool, positionId: positionId});
        _safeMint(msg.sender, tokenId);
    }

    function adjustPosition(
        uint256 tokenId,
        uint256 newMinPrice,
        uint256 newMaxPrice,
        uint32 newSlippageLimit,
        uint256 newBaseAmount,
        uint256 newQuoteAmount
    ) external onlyOwnerOrApproved(tokenId) {
        TokenPosition storage tp = _tokenPositions[tokenId];
        address pool = tp.pool;
        uint256 oldPositionId = tp.positionId;
        address owner = ownerOf(tokenId);

        // I2: the old position may already be retired (fully drained + fees collected)
        // -- Pool.collect/removeLiquidity revert PositionDoesNotExist on a retired id, so
        // only settle what is actually still live. Read the position FIRST: collect only
        // zeroes fees, never balances, so the amounts read here are unaffected by the
        // collect below. When the old position is retired, oldP's amounts are zero and
        // the pull/refund arithmetic further down degenerates correctly to "pull the full
        // new amounts from the owner".
        IPool.Position memory oldP = IPool(pool).getPosition(oldPositionId);
        if (oldP.active) {
            // Settle fees owed under the old range first.
            IPool(pool).collect(oldPositionId, owner);

            // Remove all remaining principal from the old range, sending it to this
            // contract so it can be re-supplied to the new range without an extra
            // external transfer round-trip through the NFT owner.
            if (oldP.baseAmount > 0 || oldP.quoteAmount > 0) {
                IPool(pool).removeLiquidity(oldPositionId, oldP.baseAmount, oldP.quoteAmount, address(this));
            }
        }

        (address base, address quote) = IPool(pool).getBaseQuote();
        // Pull whatever additional amount is needed beyond what the old range's withdrawal
        // already provided, from the NFT owner (who must have approved this contract for it
        // beforehand, same as any addLiquidity call).
        if (newBaseAmount > oldP.baseAmount) {
            TransferHelper.safeTransferFrom(base, owner, address(this), newBaseAmount - oldP.baseAmount);
        }
        if (newQuoteAmount > oldP.quoteAmount) {
            TransferHelper.safeTransferFrom(quote, owner, address(this), newQuoteAmount - oldP.quoteAmount);
        }
        // Symmetric case: shrinking a position (newAmount < old). The old range's full
        // withdrawal above already brought oldP.baseAmount/oldP.quoteAmount into this
        // contract, but the new range only spends newBaseAmount/newQuoteAmount of it --
        // refund the difference to the owner now, or it silently strands in this contract
        // forever (found before implementation: the growth-only pull above has no symmetric
        // counterpart without this).
        if (oldP.baseAmount > newBaseAmount) {
            TransferHelper.safeTransfer(base, owner, oldP.baseAmount - newBaseAmount);
        }
        if (oldP.quoteAmount > newQuoteAmount) {
            TransferHelper.safeTransfer(quote, owner, oldP.quoteAmount - newQuoteAmount);
        }
        if (newBaseAmount > 0) TransferHelper.safeApprove(base, pool, newBaseAmount);
        if (newQuoteAmount > 0) TransferHelper.safeApprove(quote, pool, newQuoteAmount);

        uint256 newPositionId = IPool(pool).addLiquidity(
            newMinPrice, newMaxPrice, newSlippageLimit, newBaseAmount, newQuoteAmount, address(this)
        );

        tp.positionId = newPositionId;
    }

    function removeLiquidity(uint256 tokenId, uint256 baseAmount, uint256 quoteAmount, address recipient)
        external
        onlyOwnerOrApproved(tokenId)
    {
        TokenPosition memory tp = _tokenPositions[tokenId];
        IPool(tp.pool).removeLiquidity(tp.positionId, baseAmount, quoteAmount, recipient);
    }

    function collect(uint256 tokenId, address recipient)
        external
        onlyOwnerOrApproved(tokenId)
        returns (uint256 baseFee, uint256 quoteFee)
    {
        TokenPosition memory tp = _tokenPositions[tokenId];
        return IPool(tp.pool).collect(tp.positionId, recipient);
    }

    function burn(uint256 tokenId) external onlyOwnerOrApproved(tokenId) {
        TokenPosition memory tp = _tokenPositions[tokenId];
        IPool.Position memory p = IPool(tp.pool).getPosition(tp.positionId);
        if (p.baseAmount > 0 || p.quoteAmount > 0 || p.feeOwedBase > 0 || p.feeOwedQuote > 0) {
            revert PositionNotEmpty(tokenId);
        }
        delete _tokenPositions[tokenId];
        _burn(tokenId);
    }

    function tokenPosition(uint256 tokenId) external view returns (address pool, uint256 positionId) {
        TokenPosition memory tp = _tokenPositions[tokenId];
        return (tp.pool, tp.positionId);
    }
}
