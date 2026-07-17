// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {Initializable} from "../security/Initializable.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    // I2 fix (docs/swap/2026-07-17-i2-position-lifecycle-design.md): index of live
    // position ids so the swap-time scan is O(live positions), not O(every position ever
    // created). Invariant: positions[id].active == true <=> activeIds[idxInActive[id]] == id.
    // idxInActive is only meaningful while the position is active.
    uint256[] internal activeIds;
    mapping(uint256 => uint256) internal idxInActive;
    uint32 public constant MAX_POSITIONS_PER_SWAP = 20;
    uint32 public constant DENOM = 100000000;
    uint32 public constant TWAP_WINDOW = 600; // seconds

    // See `swap`'s own comment: exists purely to keep `swap`'s stack frame within EVM
    // limits by bundling its intermediate locals into one memory value.
    struct SwapContext {
        address inputToken;
        address outputToken;
        uint256[] positionIds;
        uint256[] contributions;
        uint256 boundPrice;
        uint256 lpAmount;
        uint256 recipientOutBefore;
        uint256 recipientInBefore;
        uint32 lpOrderId;
    }

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
        idxInActive[positionId] = activeIds.length;
        activeIds.push(positionId);

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
        _deactivateIfDead(positionId);
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
        _deactivateIfDead(positionId);
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
        // Locals bundled into a memory struct (rather than kept as individual stack
        // variables) purely so `swap`'s own stack frame stays within EVM limits -- this
        // file has no `viaIR` compilation available (see foundry.toml), and the number of
        // values that need to stay live across this function's full sequence of external
        // calls otherwise exceeds it. No logic change from an all-stack-locals version:
        // same values, same order, same computations, just addressed via `ctx.<field>`.
        SwapContext memory ctx;
        ctx.inputToken = quoteToBase ? quote : base;
        ctx.outputToken = quoteToBase ? base : quote;

        TransferHelper.safeTransferFrom(ctx.inputToken, msg.sender, address(this), amountIn);

        (ctx.positionIds, ctx.contributions, ctx.boundPrice, ctx.lpAmount) = _prepareSwap(amountIn, quoteToBase);

        // Approve MatchingEngine to pull both legs from this Pool's own balance.
        TransferHelper.safeApprove(ctx.inputToken, engine, amountIn);
        TransferHelper.safeApprove(ctx.outputToken, engine, ctx.lpAmount); // outputToken == the LP-supplied side

        // design.md §4.6: recipient's own balances are the only reliable signal for what the
        // swapper leg actually filled. Pool never owns that order (recipient does, so the
        // exchange's own settlement pays them directly) and cannot inspect or cancel it
        // afterward (Orderbook.cancelOrder is owner-gated -- confirmed, see §4.6). Snapshot
        // before either leg is placed; recipient's balance is untouched by the LP leg (that
        // leg's proceeds always go to Pool, never to recipient), so this is uncontaminated.
        ctx.recipientOutBefore = IERC20(ctx.outputToken).balanceOf(recipient);
        ctx.recipientInBefore = IERC20(ctx.inputToken).balanceOf(recipient);

        // LP leg first, as a maker order, so it is resting when the swapper's leg is placed
        // and has the opportunity to actually cross against it (design doc §4.1, resolved
        // ordering documented at the top of this plan's File Structure section). Pool owns
        // this order (recipient = address(this)), so it can reliably self-cancel it below.
        ctx.lpOrderId = _placeLpLeg(quoteToBase, ctx.boundPrice, ctx.lpAmount);

        // Swapper leg second -- this is what actually crosses against the LP leg's resting
        // order (and/or other pre-existing book liquidity). recipient = recipient, never
        // Pool (design.md §4.6): the exchange pays matched proceeds and any unmatched refund
        // directly to recipient, which is exactly the balance snapshotted above and read
        // again below. isMaker = restLeftoverOnFinalHop, unchanged from the original design
        // (design doc §4.4): true rests any unfilled remainder as recipient's own order on
        // the final hop of a multi-hop route; false (the default) lets
        // MatchingEngine._detMake refund any remainder straight to recipient.
        _placeSwapperLeg(quoteToBase, ctx.boundPrice, amountIn, restLeftoverOnFinalHop, recipient);

        amountOut = IERC20(ctx.outputToken).balanceOf(recipient) - ctx.recipientOutBefore;
        leftoverIn = IERC20(ctx.inputToken).balanceOf(recipient) - ctx.recipientInBefore;

        // Self-cancel any unmatched remainder of the LP leg -- guarantees Pool never leaves
        // a persistent resting order (design doc §3.1/§4.1). cancelOrder's return value is
        // exactly how much of lpAmount did NOT match. This is legal (unlike the swapper leg
        // above) because Pool owns this order. isBid is the LOGICAL OPPOSITE of the swap's
        // own trade direction: the LP leg is always placed on the opposite side of the book
        // from the swapper (quoteToBase=true -> LP leg is a limitSell/ask -> isBid=false to
        // cancel it; quoteToBase=false -> LP leg is a limitBuy/bid -> isBid=true).
        _settleLpLeg(ctx.lpOrderId, ctx.lpAmount, quoteToBase, ctx.boundPrice, ctx.positionIds, ctx.contributions);

        emit Swap(recipient, quoteToBase, amountIn, amountOut, leftoverIn);
    }

    // Split out from `swap` for the same stack-depth reason as `_placeLpLeg`/`_settleLpLeg`
    // below -- no logic change from the inline version this replaces. MEV fix (docs/swap/
    // design.md §4.5): boundPrice must be derived from a time-weighted average, not the
    // instantaneous last-matched price -- lmp() can be moved by a single trade in the same
    // block/transaction sequence a swap lands in, and bounding this trade's price *relative
    // to* lmp() doesn't protect against that, since the reference point itself is what's
    // manipulated. Reverts (InsufficientHistory) if this pool's pair was listed less than
    // TWAP_WINDOW seconds ago -- a deliberate fail-safe, not a bug.
    function _prepareSwap(uint256 amountIn, bool quoteToBase)
        internal
        view
        returns (uint256[] memory positionIds, uint256[] memory contributions, uint256 boundPrice, uint256 lpAmount)
    {
        (uint256 marketPrice,) = IOrderbook(orderbook).twap(TWAP_WINDOW);

        uint256 totalAvailable;
        uint32 minSlippage;
        (positionIds, contributions, totalAvailable, minSlippage) = _assembleInRangePositions(marketPrice, quoteToBase);

        if (positionIds.length == 0) {
            revert NoLiquidityInRange(marketPrice);
        }

        boundPrice = quoteToBase
            ? (marketPrice * (uint256(DENOM) + minSlippage)) / DENOM
            : (marketPrice * (uint256(DENOM) - minSlippage)) / DENOM;

        // Do not try to precisely cap the LP leg's size against a converted amountIn --
        // ExchangeOrderbook._decreaseOrder auto-closes a maker order and hands the taker its
        // ENTIRE remaining deposit whenever the post-match leftover would be <= that pair's
        // own per-match dust threshold (dust = convert(price, 1, isBid), which varies with
        // price/decimals -- there is no fixed rounding offset that stays clear of it in
        // general). The LP leg is always self-cancelled within this same transaction
        // regardless of its size (see _settleLpLeg below), and cancelOrder's return value --
        // not this initial sizing -- is what actually determines matchedLpAmount either way.
        // Offering the full assembled totalAvailable keeps the match comfortably clear of any
        // dust boundary in the normal case.
        lpAmount = totalAvailable;
    }

    // Placing the LP leg is split out from `swap` purely to keep `swap`'s own stack depth
    // within EVM limits (this file has no `viaIR` compilation available -- see
    // foundry.toml). No logic change from the inline version: same branch, same arguments,
    // same order relative to the swapper leg placed immediately after this returns in `swap`.
    function _placeLpLeg(bool quoteToBase, uint256 boundPrice, uint256 lpAmount) internal returns (uint32 lpOrderId) {
        if (quoteToBase) {
            IMatchingEngine.OrderResult memory lpResult = IMatchingEngine(engine).limitSell(
                base, quote, boundPrice, lpAmount, true, MAX_POSITIONS_PER_SWAP, address(this)
            );
            lpOrderId = lpResult.id;
        } else {
            IMatchingEngine.OrderResult memory lpResult = IMatchingEngine(engine).limitBuy(
                base, quote, boundPrice, lpAmount, true, MAX_POSITIONS_PER_SWAP, address(this)
            );
            lpOrderId = lpResult.id;
        }
    }

    // Swapper leg second -- this is what actually crosses against the LP leg's resting
    // order (and/or other pre-existing book liquidity). recipient = recipient, never Pool
    // (design.md §4.6): the exchange pays matched proceeds and any unmatched refund
    // directly to recipient, which is exactly the balance snapshotted in `swap` before this
    // is called and read again after it returns. isMaker = restLeftoverOnFinalHop, unchanged
    // from the original design (design doc §4.4): true rests any unfilled remainder as
    // recipient's own order on the final hop of a multi-hop route; false (the default) lets
    // MatchingEngine._detMake refund any remainder straight to recipient. Split out from
    // `swap` for the same stack-depth reason as `_placeLpLeg` above -- no logic change from
    // the inline version this replaces.
    function _placeSwapperLeg(
        bool quoteToBase,
        uint256 boundPrice,
        uint256 amountIn,
        bool restLeftoverOnFinalHop,
        address recipient
    ) internal {
        if (quoteToBase) {
            IMatchingEngine(engine).limitBuy(
                base, quote, boundPrice, amountIn, restLeftoverOnFinalHop, MAX_POSITIONS_PER_SWAP, recipient
            );
        } else {
            IMatchingEngine(engine).limitSell(
                base, quote, boundPrice, amountIn, restLeftoverOnFinalHop, MAX_POSITIONS_PER_SWAP, recipient
            );
        }
    }

    // Split out from `swap` for the same stack-depth reason as `_placeLpLeg` above -- no
    // logic change from the inline version this replaces.
    function _settleLpLeg(
        uint32 lpOrderId,
        uint256 lpAmount,
        bool quoteToBase,
        uint256 boundPrice,
        uint256[] memory positionIds,
        uint256[] memory contributions
    ) internal {
        // Self-cancel any unmatched remainder of the LP leg -- guarantees Pool never leaves
        // a persistent resting order (design doc §3.1/§4.1). cancelOrder's return value is
        // exactly how much of lpAmount did NOT match. This is legal (unlike the swapper leg
        // above) because Pool owns this order. isBid is the LOGICAL OPPOSITE of the swap's
        // own trade direction: the LP leg is always placed on the opposite side of the book
        // from the swapper (quoteToBase=true -> LP leg is a limitSell/ask -> isBid=false to
        // cancel it; quoteToBase=false -> LP leg is a limitBuy/bid -> isBid=true).
        uint256 lpUnmatched = 0;
        if (lpOrderId > 0) {
            lpUnmatched = IMatchingEngine(engine).cancelOrder(base, quote, !quoteToBase, lpOrderId);
        }
        uint256 matchedLpAmount = lpAmount - lpUnmatched;

        if (matchedLpAmount > 0) {
            uint32 makerFeeRate = IMatchingEngine(engine).feeOf(base, quote, address(this), true);
            uint256 grossLpProceeds = IOrderbook(orderbook).convert(boundPrice, matchedLpAmount, quoteToBase);
            uint256 lpFee = (grossLpProceeds * makerFeeRate) / DENOM;
            uint256 poolShareOfFee = (lpFee * IMatchingEngine(engine).poolFeeShare()) / DENOM;
            // Principal leg only -- poolShareOfFee is routed separately via creditFee below,
            // so folding it in here as well would double-credit it (once into principal,
            // once into feeOwedQuote/feeOwedBase).
            uint256 lpPrincipalReceived = grossLpProceeds - lpFee;

            _settlePositionContributions(positionIds, contributions, quoteToBase, matchedLpAmount, lpPrincipalReceived);

            if (poolShareOfFee > 0) {
                this.creditFee(positionIds, contributions, !quoteToBase, poolShareOfFee);
            }

            // I2: retire any contributing position this settlement fully drained (zero
            // principal both sides, zero fees owed -- e.g. a dust position whose
            // proportional received-credit floor-divides to 0). MUST run after creditFee
            // above: crediting fees to an already-retired position would strand them
            // behind collect's PositionDoesNotExist gate. Mutating activeIds here is safe:
            // _assembleInRangePositions already ran and its results are held in memory.
            for (uint256 i = 0; i < positionIds.length; i++) {
                _deactivateIfDead(positionIds[i]);
            }
        }
    }

    function _assembleInRangePositions(uint256 marketPrice, bool quoteToBase)
        internal
        view
        returns (uint256[] memory positionIds, uint256[] memory contributions, uint256 totalAvailable, uint32 minSlippage)
    {
        uint256[] memory idsBuf = new uint256[](MAX_POSITIONS_PER_SWAP);
        uint256[] memory contribBuf = new uint256[](MAX_POSITIONS_PER_SWAP);
        uint32 count = 0;
        minSlippage = type(uint32).max;

        // I2 fix: iterate only live positions -- one storage read of the id list up
        // front, then 20 selection passes over memory. Both the scan and the scratch
        // buffer are sized by the LIVE count; the old `1..nextPositionId` loop and its
        // `new bool[](nextPositionId + 1)` buffer each grew forever with dead history.
        // Tie-break nuance vs the old code: positions are visited in activeIds order
        // (permuted by swap-and-pop), not ascending id order, so among >20 in-range
        // positions with IDENTICAL slippageLimit the selected subset can differ from the
        // old code's. Selection is still tightest-slippage-first; contribution math is
        // order-independent.
        uint256[] memory ids = activeIds;
        bool[] memory used = new bool[](ids.length);

        for (uint32 pass = 0; pass < MAX_POSITIONS_PER_SWAP; pass++) {
            uint256 bestK = type(uint256).max;
            uint32 bestSlippage = type(uint32).max;

            for (uint256 k = 0; k < ids.length; k++) {
                if (used[k]) continue;
                Position storage p = positions[ids[k]];
                if (!p.active) continue; // belt-and-braces; the activeIds invariant makes this redundant
                if (p.minPrice > marketPrice || p.maxPrice < marketPrice) continue;
                uint256 available = quoteToBase ? p.baseAmount : p.quoteAmount;
                if (available == 0) continue;
                if (p.slippageLimit < bestSlippage) {
                    bestSlippage = p.slippageLimit;
                    bestK = k;
                }
            }

            if (bestK == type(uint256).max) break;

            used[bestK] = true;
            uint256 bestId = ids[bestK];
            uint256 contribution = quoteToBase ? positions[bestId].baseAmount : positions[bestId].quoteAmount;
            idsBuf[count] = bestId;
            contribBuf[count] = contribution;
            totalAvailable += contribution;
            if (bestSlippage < minSlippage) minSlippage = bestSlippage;
            count++;
        }

        if (count == 0) {
            minSlippage = 0;
        }

        positionIds = new uint256[](count);
        contributions = new uint256[](count);
        for (uint32 i = 0; i < count; i++) {
            positionIds[i] = idsBuf[i];
            contributions[i] = contribBuf[i];
        }
    }

    function _settlePositionContributions(
        uint256[] memory positionIds,
        uint256[] memory contributions,
        bool quoteToBase,
        uint256 matchedLpAmount,
        uint256 lpPrincipalReceived
    ) internal {
        // Reduce each contributing position's supplied-side balance proportionally to how
        // much of the total assembled amount actually matched, and credit back the other
        // side with its proportional share of what the LP leg received in return -- this is
        // the "position holdings shift composition as price moves through range" behavior
        // from design doc §4.3. An earlier draft of this function only did the decrement
        // half and never credited back the received side; fixed here.
        uint256 totalContributed;
        for (uint256 i = 0; i < contributions.length; i++) {
            totalContributed += contributions[i];
        }
        if (totalContributed == 0) return;

        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 suppliedUsed = (matchedLpAmount * contributions[i]) / totalContributed;
            uint256 receivedCredit = (lpPrincipalReceived * contributions[i]) / totalContributed;
            if (quoteToBase) {
                positions[positionIds[i]].baseAmount -= suppliedUsed;
                positions[positionIds[i]].quoteAmount += receivedCredit;
            } else {
                positions[positionIds[i]].quoteAmount -= suppliedUsed;
                positions[positionIds[i]].baseAmount += receivedCredit;
            }
        }
    }

    function activePositionsLength() external view returns (uint256) {
        return activeIds.length;
    }

    // Retire a position once it is economically dead: zero principal on both sides AND
    // zero fees owed. A drained position with pending fees stays active so collect keeps
    // working; it retires when collect zeroes the fees. Once retired, no code path can
    // credit an inactive position again (swap settlement only touches ids assembled from
    // the active set, and fee crediting runs before the retirement sweep in _settleLpLeg),
    // so retirement is permanent. The p.active guard makes this idempotent -- a reentrant
    // or repeated call is a no-op, never a double swap-and-pop.
    function _deactivateIfDead(uint256 positionId) internal {
        Position storage p = positions[positionId];
        if (
            p.active && p.baseAmount == 0 && p.quoteAmount == 0 && p.feeOwedBase == 0
                && p.feeOwedQuote == 0
        ) {
            p.active = false;
            uint256 idx = idxInActive[positionId];
            uint256 lastId = activeIds[activeIds.length - 1];
            activeIds[idx] = lastId;
            idxInActive[lastId] = idx;
            activeIds.pop();
            delete idxInActive[positionId];
            emit PositionDeactivated(positionId);
        }
    }

    function _absdiff(uint8 a, uint8 b) internal pure returns (uint8, bool) {
        return (a > b ? a - b : b - a, a > b);
    }
}
