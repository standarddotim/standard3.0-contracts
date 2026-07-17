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
        // Assembled positions in ascending (slippageLimit, positionId) order -- the
        // paper's ascending-s-then-earliest-position discipline. Positions with equal
        // slippageLimit form one "tier"; tiers are contiguous runs in these arrays.
        uint256[] positionIds;
        uint256[] contributions;
        uint32[] slippages;
        uint256 marketPrice; // TWAP reference this swap prices against
        uint256 totalAvailable;
        uint256 recipientOutBefore;
        uint256 recipientInBefore;
        // Pool's own input-token balance right after pulling amountIn and before any leg
        // is placed. Settlement derives actual LP proceeds from the delta against this --
        // never from a reconstruction at the bound price -- so better-priced third-party
        // crossings are credited to positions instead of stranding in the pool.
        uint256 poolInBefore;
        // One LP leg per tier: tier t spans positions [tierStart[t], tierStart[t+1]),
        // is offered at tierBounds[t] = TWAP * (1 +/- s_t), and totals tierAmounts[t].
        uint256[] tierStart;
        uint256[] tierBounds;
        uint256[] tierAmounts;
        uint32[] tierOrderIds;
    }

    // Bundles _assembleInRangePositions' scratch buffers into one memory value for the
    // same stack-depth reason as SwapContext above.
    struct AssemblyBuf {
        uint256[] idsBuf;
        uint256[] contribBuf;
        uint32[] slipBuf;
        uint256[] ids;
        bool[] used;
        uint32 count;
    }

    // Bundles _settleTiers' locals into one memory value for the same stack-depth reason
    // as SwapContext above.
    struct TierSettle {
        uint256[] matched;
        uint256[] expected; // principal + fee rebate the tier would earn at its bound price
        uint256[] principal; // bound-priced principal component of `expected`
        uint256 totalMatched;
        uint256 totalExpected;
        uint256 actualProceeds;
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
        // A tolerance at or above 100% is meaningless economically and, worse, weaponizable:
        // if such a position were ever the widest tier assembled, the sell-side bound
        // TWAP * (DENOM - s) / DENOM would underflow and revert every base->quote swap in
        // its range. The eventual liquidity-scaled cap (paper §3.4) will tighten this
        // further; this guard only excludes the degenerate range.
        if (slippageLimit >= DENOM) revert InvalidSlippageLimit(slippageLimit);
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

        _prepareSwap(ctx, quoteToBase);

        // Approve MatchingEngine to pull every leg from this Pool's own balance.
        TransferHelper.safeApprove(ctx.inputToken, engine, amountIn);
        TransferHelper.safeApprove(ctx.outputToken, engine, ctx.totalAvailable); // outputToken == the LP-supplied side

        // design.md §4.6: recipient's own balances are the only reliable signal for what the
        // swapper leg actually filled. Pool never owns that order (recipient does, so the
        // exchange's own settlement pays them directly) and cannot inspect or cancel it
        // afterward (Orderbook.cancelOrder is owner-gated -- confirmed, see §4.6). Snapshot
        // before any leg is placed; recipient's balance is untouched by the LP legs (their
        // proceeds always go to Pool, never to recipient), so this is uncontaminated.
        ctx.recipientOutBefore = IERC20(ctx.outputToken).balanceOf(recipient);
        ctx.recipientInBefore = IERC20(ctx.inputToken).balanceOf(recipient);
        // Snapshot for settlement's balance-delta proceeds measurement -- must be taken
        // before the LP legs go in, because a leg can cross pre-existing opposite orders
        // at placement time and be paid immediately.
        ctx.poolInBefore = IERC20(ctx.inputToken).balanceOf(address(this));

        // LP legs first, one maker order per tolerance tier at that tier's own bound
        // price, so they are resting when the swapper's leg is placed and can actually
        // cross against it (design doc §4.1). Tightest tier = best price for the swapper,
        // so price priority in the matching engine fills tighter tiers first -- the
        // cross-tier half of the paper's ascending-s discipline is enforced by the book
        // itself. Pool owns these orders (recipient = address(this)), so it can reliably
        // self-cancel them below.
        _placeTierLegs(ctx, quoteToBase);

        // Swapper leg second -- this is what actually crosses against the LP legs' resting
        // orders (and/or other pre-existing book liquidity). Its limit price is the WIDEST
        // assembled tier's bound: that is the worst price any pool position has agreed to,
        // and the swapper walks the tiers best-first up to it (the paper's tiered-book
        // execution model, §4.2). recipient = recipient, never Pool (design.md §4.6): the
        // exchange pays matched proceeds and any unmatched refund directly to recipient,
        // which is exactly the balance snapshotted above and read again below.
        // isMaker = restLeftoverOnFinalHop, unchanged from the original design (design doc
        // §4.4): true rests any unfilled remainder as recipient's own order on the final
        // hop of a multi-hop route; false (the default) lets MatchingEngine._detMake
        // refund any remainder straight to recipient.
        _placeSwapperLeg(
            quoteToBase, ctx.tierBounds[ctx.tierBounds.length - 1], amountIn, restLeftoverOnFinalHop, recipient
        );

        amountOut = IERC20(ctx.outputToken).balanceOf(recipient) - ctx.recipientOutBefore;
        leftoverIn = IERC20(ctx.inputToken).balanceOf(recipient) - ctx.recipientInBefore;

        // Self-cancel any unmatched remainder of every LP leg -- guarantees Pool never
        // leaves a persistent resting order (design doc §3.1/§4.1) -- then credit each
        // contributing position at its own tier's terms from the pool's measured proceeds.
        _settleTiers(ctx, quoteToBase, amountIn);

        emit Swap(recipient, quoteToBase, amountIn, amountOut, leftoverIn);
    }

    // Split out from `swap` for the same stack-depth reason as `_placeTierLegs`/
    // `_settleTiers` below. MEV fix (docs/swap/design.md §4.5): every tier bound is derived
    // from a time-weighted average, not the instantaneous last-matched price -- lmp() can be
    // moved by a single trade in the same block/transaction sequence a swap lands in, and
    // bounding this trade's price *relative to* lmp() doesn't protect against that, since
    // the reference point itself is what's manipulated. Reverts (InsufficientHistory) if
    // this pool's pair was listed less than TWAP_WINDOW seconds ago -- a deliberate
    // fail-safe, not a bug.
    function _prepareSwap(SwapContext memory ctx, bool quoteToBase) internal view {
        (ctx.marketPrice,) = IOrderbook(orderbook).twap(TWAP_WINDOW);

        (ctx.positionIds, ctx.contributions, ctx.slippages, ctx.totalAvailable) =
            _assembleInRangePositions(ctx.marketPrice, quoteToBase);

        if (ctx.positionIds.length == 0) {
            revert NoLiquidityInRange(ctx.marketPrice);
        }

        _layoutTiers(ctx, quoteToBase);
    }

    // Groups the assembled positions -- already sorted ascending (slippageLimit, id) -- into
    // contiguous equal-slippage tiers and computes each tier's own execution bound
    // TWAP * (1 +/- s_tier). This is what makes a position's fill terms its OWN quoted
    // tolerance (paper §3.4) rather than the pool-wide minimum: each tier becomes a separate
    // maker order at its own price in _placeTierLegs.
    //
    // Tier sizing note (carried over from the single-leg version): do not try to precisely
    // cap a leg's size against a converted amountIn -- ExchangeOrderbook._decreaseOrder
    // auto-closes a maker order and hands the taker its ENTIRE remaining deposit whenever
    // the post-match leftover would be <= that pair's own per-match dust threshold. Every
    // leg is self-cancelled within this same transaction regardless of its size (see
    // _settleTiers below), and cancelOrder's return value -- not this initial sizing -- is
    // what actually determines each tier's matched amount either way.
    function _layoutTiers(SwapContext memory ctx, bool quoteToBase) internal pure {
        uint256 n = ctx.positionIds.length;
        uint256 nTiers = 1;
        for (uint256 i = 1; i < n; i++) {
            if (ctx.slippages[i] != ctx.slippages[i - 1]) nTiers++;
        }

        ctx.tierStart = new uint256[](nTiers + 1);
        ctx.tierBounds = new uint256[](nTiers);
        ctx.tierAmounts = new uint256[](nTiers);
        ctx.tierOrderIds = new uint32[](nTiers);

        uint256 t = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0 && ctx.slippages[i] != ctx.slippages[i - 1]) {
                t++;
                ctx.tierStart[t] = i;
            }
            ctx.tierAmounts[t] += ctx.contributions[i];
        }
        ctx.tierStart[nTiers] = n;

        for (t = 0; t < nTiers; t++) {
            uint32 s = ctx.slippages[ctx.tierStart[t]];
            ctx.tierBounds[t] = quoteToBase
                ? (ctx.marketPrice * (uint256(DENOM) + s)) / DENOM
                : (ctx.marketPrice * (uint256(DENOM) - s)) / DENOM;
        }
    }

    // Places one maker order per tier at that tier's own bound, tightest tier first. The
    // legs are all on the same side of the book, so they can never cross each other; a leg
    // CAN cross unrelated pre-existing opposite orders at placement -- a deliberate
    // composability property, and the reason settlement measures proceeds by balance delta.
    // Split out from `swap` purely to keep `swap`'s own stack depth within EVM limits
    // (this file has no `viaIR` compilation available -- see foundry.toml).
    function _placeTierLegs(SwapContext memory ctx, bool quoteToBase) internal {
        for (uint256 t = 0; t < ctx.tierBounds.length; t++) {
            if (quoteToBase) {
                IMatchingEngine.OrderResult memory lpResult = IMatchingEngine(engine).limitSell(
                    base, quote, ctx.tierBounds[t], ctx.tierAmounts[t], true, MAX_POSITIONS_PER_SWAP, address(this)
                );
                ctx.tierOrderIds[t] = lpResult.id;
            } else {
                IMatchingEngine.OrderResult memory lpResult = IMatchingEngine(engine).limitBuy(
                    base, quote, ctx.tierBounds[t], ctx.tierAmounts[t], true, MAX_POSITIONS_PER_SWAP, address(this)
                );
                ctx.tierOrderIds[t] = lpResult.id;
            }
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

    // Cancels every tier leg, measures the pool's ACTUAL proceeds by balance delta, and
    // credits each contributing position at its own tier's terms. Split out from `swap`
    // for the same stack-depth reason as `_placeTierLegs` above.
    //
    // Self-cancelling each leg guarantees Pool never leaves a persistent resting order
    // (design doc §3.1/§4.1). cancelOrder's return value is exactly how much of that
    // tier's amount did NOT match. This is legal (unlike the swapper leg) because Pool
    // owns these orders. isBid is the LOGICAL OPPOSITE of the swap's own trade direction:
    // the LP legs are always on the opposite side of the book from the swapper
    // (quoteToBase=true -> asks -> isBid=false to cancel; quoteToBase=false -> bids ->
    // isBid=true).
    //
    // Proceeds accounting: the engine pays the pool in-band as fills happen (principal net
    // of maker fee, plus the poolFeeShare rebate -- see Orderbook._sendFunds), and a leg
    // that crossed a better-priced third-party order is paid at THAT price, above its tier
    // bound. Reconstructing proceeds from the bound price would strand exactly that
    // surplus in the pool (the old single-leg version's bug); instead the total is
    // measured as an input-token balance delta and split across tiers in proportion to
    // each tier's bound-priced entitlement, so surplus (or a taker-fee shortfall, if a leg
    // took liquidity at placement) is distributed proportionally and nothing is stranded
    // beyond integer dust.
    function _settleTiers(SwapContext memory ctx, bool quoteToBase, uint256 amountIn) internal {
        TierSettle memory ts;
        uint256 nTiers = ctx.tierOrderIds.length;
        ts.matched = new uint256[](nTiers);
        ts.expected = new uint256[](nTiers);
        ts.principal = new uint256[](nTiers);

        for (uint256 t = 0; t < nTiers; t++) {
            uint256 unmatched = 0;
            if (ctx.tierOrderIds[t] > 0) {
                unmatched = IMatchingEngine(engine).cancelOrder(base, quote, !quoteToBase, ctx.tierOrderIds[t]);
            }
            ts.matched[t] = ctx.tierAmounts[t] - unmatched;
            ts.totalMatched += ts.matched[t];
        }
        if (ts.totalMatched == 0) return;

        uint32 makerFeeRate = IMatchingEngine(engine).feeOf(base, quote, address(this), true);
        uint256 rebateShare = IMatchingEngine(engine).poolFeeShare();
        for (uint256 t = 0; t < nTiers; t++) {
            if (ts.matched[t] == 0) continue;
            uint256 gross = IOrderbook(orderbook).convert(ctx.tierBounds[t], ts.matched[t], quoteToBase);
            uint256 fee = (gross * makerFeeRate) / DENOM;
            ts.principal[t] = gross - fee;
            ts.expected[t] = ts.principal[t] + (fee * rebateShare) / DENOM;
            ts.totalExpected += ts.expected[t];
        }

        // amountIn is added back because the swapper leg's placement pulled exactly
        // amountIn of the input token out of the pool after poolInBefore was snapshotted
        // (any unfilled remainder is refunded or rested to RECIPIENT by the engine, never
        // to the pool).
        // Add amountIn BEFORE subtracting the snapshot: the snapshot includes amountIn
        // (taken after pulling it) while the current balance no longer does, so the
        // subtraction-first order underflows whenever proceeds < amountIn.
        ts.actualProceeds = IERC20(ctx.inputToken).balanceOf(address(this)) + amountIn - ctx.poolInBefore;

        for (uint256 t = 0; t < nTiers; t++) {
            if (ts.matched[t] == 0 || ts.expected[t] == 0) continue;
            uint256 actualTier =
                ts.totalExpected == 0 ? 0 : (ts.actualProceeds * ts.expected[t]) / ts.totalExpected;
            // Scale the rebate component and give principal the remainder -- when actual
            // == expected (the common exact-fill case) this reproduces the bound-priced
            // split to the wei, and any better-price surplus lands on the principal side,
            // which is where a better fill price economically belongs.
            uint256 rebateActual = (actualTier * (ts.expected[t] - ts.principal[t])) / ts.expected[t];
            _settleTierPositions(ctx, t, ts.matched[t], actualTier - rebateActual, rebateActual, quoteToBase);
        }

        // I2: retire any contributing position this settlement fully drained (zero
        // principal both sides, zero fees owed -- e.g. a dust position whose
        // proportional received-credit floor-divides to 0). MUST run after the fee
        // crediting inside _settleTierPositions: crediting fees to an already-retired
        // position would strand them behind collect's PositionDoesNotExist gate. Mutating
        // activeIds here is safe: _assembleInRangePositions already ran and its results
        // are held in memory.
        for (uint256 i = 0; i < ctx.positionIds.length; i++) {
            _deactivateIfDead(ctx.positionIds[i]);
        }
    }

    // Allocates one tier's matched amount across its positions as a WATERFALL in position
    // order -- and tier order is ascending id, i.e. age -- so the earliest position at a
    // tolerance is drained fully before a younger one supplies anything. This is the
    // paper's JIT defense (§4.6) made literal: a same-block position minted at the same
    // tolerance as an incumbent takes zero flow (volume or fees) until every older
    // same-tolerance position is exhausted; to take flow it must quote strictly tighter,
    // which hands the swapper a better price instead of siphoning a passive LP's income.
    // Principal is credited pro-rata to the amount each position actually supplied; the
    // tier's fee rebate is credited through creditFee with the same supplied amounts as
    // shares.
    function _settleTierPositions(
        SwapContext memory ctx,
        uint256 t,
        uint256 matched,
        uint256 principalActual,
        uint256 rebateActual,
        bool quoteToBase
    ) internal {
        uint256 startI = ctx.tierStart[t];
        uint256 len = ctx.tierStart[t + 1] - startI;
        uint256[] memory tierIds = new uint256[](len);
        uint256[] memory used = new uint256[](len);

        uint256 remaining = matched;
        for (uint256 j = 0; j < len; j++) {
            uint256 contribution = ctx.contributions[startI + j];
            uint256 u = contribution < remaining ? contribution : remaining;
            remaining -= u;
            tierIds[j] = ctx.positionIds[startI + j];
            used[j] = u;
            if (u > 0) {
                uint256 credit = (principalActual * u) / matched;
                Position storage p = positions[tierIds[j]];
                if (quoteToBase) {
                    p.baseAmount -= u;
                    p.quoteAmount += credit;
                } else {
                    p.quoteAmount -= u;
                    p.baseAmount += credit;
                }
            }
        }

        if (rebateActual > 0) {
            this.creditFee(tierIds, used, !quoteToBase, rebateActual);
        }
    }

    function _assembleInRangePositions(uint256 marketPrice, bool quoteToBase)
        internal
        view
        returns (
            uint256[] memory positionIds,
            uint256[] memory contributions,
            uint32[] memory slippages,
            uint256 totalAvailable
        )
    {
        AssemblyBuf memory buf;
        buf.idsBuf = new uint256[](MAX_POSITIONS_PER_SWAP);
        buf.contribBuf = new uint256[](MAX_POSITIONS_PER_SWAP);
        buf.slipBuf = new uint32[](MAX_POSITIONS_PER_SWAP);

        // I2 fix: iterate only live positions -- one up-front storage copy of the id
        // list (one SLOAD per element), then 20 selection passes over memory. Both the
        // scan and the scratch buffer are sized by the LIVE count; the old
        // `1..nextPositionId` loop and its `new bool[](nextPositionId + 1)` buffer each
        // grew forever with dead history.
        //
        // Selection is ascending (slippageLimit, positionId): tightest tolerance first,
        // ties broken by position AGE (lower id = older), regardless of the activeIds
        // permutation swap-and-pop leaves behind. The age tie-break is load-bearing for
        // the within-tier waterfall in _settleTierPositions -- it is what makes "a
        // same-tolerance JIT position takes nothing until every older position is
        // exhausted" true even among >MAX_POSITIONS_PER_SWAP in-range candidates.
        buf.ids = activeIds;
        buf.used = new bool[](buf.ids.length);

        for (uint32 pass = 0; pass < MAX_POSITIONS_PER_SWAP; pass++) {
            uint256 bestK = type(uint256).max;
            uint32 bestSlippage = type(uint32).max;

            for (uint256 k = 0; k < buf.ids.length; k++) {
                if (buf.used[k]) continue;
                Position storage p = positions[buf.ids[k]];
                if (!p.active) continue; // belt-and-braces; the activeIds invariant makes this redundant
                if (p.minPrice > marketPrice || p.maxPrice < marketPrice) continue;
                if ((quoteToBase ? p.baseAmount : p.quoteAmount) == 0) continue;
                if (
                    bestK == type(uint256).max || p.slippageLimit < bestSlippage
                        || (p.slippageLimit == bestSlippage && buf.ids[k] < buf.ids[bestK])
                ) {
                    bestSlippage = p.slippageLimit;
                    bestK = k;
                }
            }

            if (bestK == type(uint256).max) break;

            buf.used[bestK] = true;
            uint256 bestId = buf.ids[bestK];
            uint256 contribution = quoteToBase ? positions[bestId].baseAmount : positions[bestId].quoteAmount;
            buf.idsBuf[buf.count] = bestId;
            buf.contribBuf[buf.count] = contribution;
            buf.slipBuf[buf.count] = bestSlippage;
            totalAvailable += contribution;
            buf.count++;
        }

        positionIds = new uint256[](buf.count);
        contributions = new uint256[](buf.count);
        slippages = new uint32[](buf.count);
        for (uint32 i = 0; i < buf.count; i++) {
            positionIds[i] = buf.idsBuf[i];
            contributions[i] = buf.contribBuf[i];
            slippages[i] = buf.slipBuf[i];
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
            // When retiring the last (or only) element, lastId == positionId and these
            // two writes are intentional self-assign no-ops -- correct because the
            // delete below runs after them. Do not "simplify" by branching on idx.
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
