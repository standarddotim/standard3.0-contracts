// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IMatchingEngine} from "../interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {TransferHelper} from "./TransferHelper.sol";

library MatchingLib {
    event OrderMatched(
        address pair,
        uint16 orderHistoryId,
        uint256 id,
        bool isBid,
        uint256 price,
        uint256 total,
        bool clear,
        IMatchingEngine.OrderMatch orderMatch
    );

    event NewMarketPrice(address pair, uint256 price, bool isBid);

    error TooManyMatches(uint256 n);

    function matchAt(
        IMatchingEngine.MatchAtInput memory matchAtInput
    ) public returns (uint256 remaining, uint32 k) {
        remaining = matchAtInput.amount;
        while (
            remaining > 0 &&
            !IOrderbook(matchAtInput.pair).isEmpty(!matchAtInput.isBid, matchAtInput.price) &&
            matchAtInput.i < matchAtInput.n
        ) {
            (uint32 orderId, uint256 required, bool clear) = IOrderbook(matchAtInput.pair).fpop(
                !matchAtInput.isBid, matchAtInput.price, remaining
            );
            if (remaining <= required) {
                TransferHelper.safeTransfer(matchAtInput.give, matchAtInput.pair, remaining);
                IMatchingEngine.OrderMatch memory orderMatch = IOrderbook(matchAtInput.pair).execute(
                    orderId, !matchAtInput.isBid, matchAtInput.recipient, remaining, clear
                );
                emit OrderMatched(
                    matchAtInput.pair, matchAtInput.orderHistoryId, orderId,
                    matchAtInput.isBid, matchAtInput.price, matchAtInput.total, clear, orderMatch
                );
                return (0, matchAtInput.n);
            } else if (required == 0) {
                ++matchAtInput.i;
                continue;
            } else {
                remaining -= required;
                TransferHelper.safeTransfer(matchAtInput.give, matchAtInput.pair, required);
                IMatchingEngine.OrderMatch memory orderMatch = IOrderbook(matchAtInput.pair).execute(
                    orderId, !matchAtInput.isBid, matchAtInput.recipient, required, clear
                );
                emit OrderMatched(
                    matchAtInput.pair, matchAtInput.orderHistoryId, orderId,
                    matchAtInput.isBid, matchAtInput.price, matchAtInput.total, clear, orderMatch
                );
                ++matchAtInput.i;
            }
        }
        k = matchAtInput.i;
        return (remaining, k);
    }

    function limitOrder(
        address pair,
        uint256 amount,
        address give,
        address recipient,
        bool isBid,
        uint256 limitPrice,
        uint32 n,
        uint16 orderHistoryId,
        uint32 maxMatches
    ) public returns (uint256 remaining, uint256 bidHead, uint256 askHead) {
        if (n > maxMatches) {
            revert TooManyMatches(n);
        }
        remaining = amount;
        IMatchingEngine.LimitOrderState memory state = IMatchingEngine.LimitOrderState({
            lmp: IOrderbook(pair).lmp(),
            i: 0,
            prevI: 0
        });
        bidHead = IOrderbook(pair).clearEmptyHead(true);
        askHead = IOrderbook(pair).clearEmptyHead(false);
        if (isBid) {
            if (state.lmp != 0) {
                if (askHead != 0 && limitPrice < askHead) {
                    return (remaining, bidHead, askHead);
                } else if (askHead == 0) {
                    return (remaining, bidHead, askHead);
                }
            }
            while (remaining > 0 && askHead != 0 && askHead <= limitPrice && state.i < n) {
                state.lmp = askHead;
                state.prevI = state.i;
                (remaining, state.i) = matchAt(IMatchingEngine.MatchAtInput({
                    pair: pair,
                    give: give,
                    recipient: recipient,
                    isBid: isBid,
                    amount: remaining,
                    total: amount,
                    price: askHead,
                    i: state.i,
                    n: n,
                    orderHistoryId: orderHistoryId
                }));
                askHead = (state.i == state.prevI) ? 0 : IOrderbook(pair).clearEmptyHead(false);
            }
            bidHead = IOrderbook(pair).clearEmptyHead(true);
        } else {
            if (state.lmp != 0) {
                if (bidHead != 0 && limitPrice > bidHead) {
                    return (remaining, bidHead, askHead);
                } else if (bidHead == 0) {
                    return (remaining, bidHead, askHead);
                }
            }
            while (remaining > 0 && bidHead != 0 && bidHead >= limitPrice && state.i < n) {
                state.lmp = bidHead;
                state.prevI = state.i;
                (remaining, state.i) = matchAt(IMatchingEngine.MatchAtInput({
                    pair: pair,
                    give: give,
                    recipient: recipient,
                    isBid: isBid,
                    amount: remaining,
                    total: amount,
                    price: bidHead,
                    i: state.i,
                    n: n,
                    orderHistoryId: orderHistoryId
                }));
                bidHead = (state.i == state.prevI) ? 0 : IOrderbook(pair).clearEmptyHead(true);
            }
            askHead = IOrderbook(pair).clearEmptyHead(false);
        }
        if (state.lmp != 0) {
            IOrderbook(pair).setLmp(state.lmp);
            emit NewMarketPrice(pair, state.lmp, isBid);
        }
        return (remaining, bidHead, askHead);
    }
}
