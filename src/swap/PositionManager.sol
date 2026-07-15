// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPool} from "./interfaces/IPool.sol";

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

    function adjustPosition(uint256, uint256, uint256, uint32, uint256, uint256) external pure {
        revert("not implemented until Task 13");
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
