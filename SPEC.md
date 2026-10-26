# MilestoneEscrow — Specification

## 1. Purpose
Trust-minimised escrow for freelance work. A **client** locks the full price of a job, split into
milestones. A **provider** delivers milestone by milestone and is paid as each is approved. A
neutral **arbiter** settles disputes. Funds never sit with a party that has not earned them,
and every party has a timeout-based exit so nobody can hold funds hostage forever.

## 2. Roles
| Role | Can |
|---|---|
| Client (`msg.sender` of `createEscrow`) | fund, cancel (unfunded), approve milestones (direct or EIP-712 signature), refund expired milestones, raise dispute, timeout-resolve dispute |
| Provider | submit milestones, claim after review period, voluntarily refund, raise dispute, timeout-resolve dispute |
| Arbiter | `resolveDispute(id, providerShareBps)` only. Cannot receive funds. |
| Owner (protocol) | `setFee` for **future** escrows only, capped at 5%. Cannot touch escrowed funds. |
| Anyone | relay a signed client approval |

Client, provider and arbiter must be three distinct non-zero addresses. Any of them may be an EOA
or a smart contract account.

## 3. Lifecycle / state machine
Escrow status: `Created → Funded → {Completed | Refunded | Disputed → Resolved}`, `Created → Cancelled`.

Milestone status: `Pending → Submitted → Released`, `Pending → Released` (early approval),
`Pending → Refunded`, `Submitted → Refunded` (provider walk-away), `Pending|Submitted → Resolved` (dispute).

"Approved" is an instantaneous step: approval emits `MilestoneApproved` and immediately releases
(credits) the funds, emitting `MilestoneReleased`. There is no separate "approved but unreleased" state;
this removes a whole class of stuck-funds bugs.

| Transition | Who | Condition |
|---|---|---|
| createEscrow | client | 1–50 milestones, each 0 < amt ≤ 2^128-1; review ∈ [1h, 30d]; deadline in future |
| fund | client | Created; exact `msg.value` (ETH) or exact token amount received |
| cancel | client | Created (nothing locked) |
| submitMilestone | provider | Funded, milestone Pending |
| approveMilestone / approveMilestoneWithSig | client / relayer | Funded, milestone Pending or Submitted |
| claimAfterReview | provider | Funded, Submitted, `now ≥ submittedAt + reviewPeriod` |
| refundExpired | client | Funded, `now > deadline`; refunds **Pending** milestones only |
| providerRefund | provider | Funded; refunds all unsettled |
| raiseDispute | client/provider | Funded; freezes all milestone actions |
| resolveDispute | arbiter | Disputed; splits all unsettled by bps |
| resolveAfterArbiterTimeout | client/provider | Disputed for ≥ 30 days; Submitted→provider, Pending→client |

When `settled == total` the escrow closes as `Completed` (provider received something) or `Refunded`.

### Timeouts
* **Review period** (per escrow, 1h–30d): protects the provider from a silent client.
* **Deadline**: protects the client from a silent provider (only un-submitted work is refundable).
* **Arbiter timeout** (30d, constant): protects both from an absent arbiter.
* **Signature deadline**: bounds the life of an off-chain approval.

## 4. Assets
`token == address(0)` means native ETH; otherwise an ERC-20 handled with `SafeERC20`
(handles non-bool-returning tokens like USDT). `fund` measures the balance delta and **reverts**
with `FeeOnTransferNotSupported` unless exactly `total` arrived. Rebasing tokens are unsupported (documented, not enforceable).

## 5. EIP-712 approvals
Domain: `name="MilestoneEscrow", version="1", chainId, verifyingContract`.
```
ApproveMilestone(uint256 escrowId,uint256 index,uint256 amount,uint256 sigDeadline)
```
Verified with OpenZeppelin `SignatureChecker.isValidSignatureNow(client, digest, sig)`: ECDSA for EOAs,
`isValidSignature` (ERC-1271) for contract clients. No nonce is needed: a milestone can only move to
`Released` once, so a signature is single-use by construction; `amount` binding means a signature cannot
be reused for a different milestone value; the domain prevents cross-chain/cross-deployment replay.

## 6. Pull payments
Releases, refunds and resolutions only **credit** `withdrawable(account, token)`. Accounts call
`withdraw(token)` (non-reentrant, checks-effects-interactions). A reverting recipient therefore can
only block its own withdrawal, never another party's state transition.

## 7. Fees
Optional protocol fee in bps, **hard-capped at 500 (5%)**, snapshotted into each escrow at creation
(owner changes never affect live escrows). Charged only on amounts paid to the provider; refunds
to the client are fee-free. The arbiter receives no on-chain fee (arbiter compensation is off-chain;
see open items).

## 8. Events
`EscrowCreated, EscrowFunded, EscrowCancelled, MilestoneSubmitted, MilestoneApproved, MilestoneReleased,
MilestoneRefunded, DisputeRaised, DisputeResolved, StatusChanged, Withdrawn, FeeUpdated`.

## 9. Threat model
| Threat | Mitigation |
|---|---|
| Reentrancy (ETH receive hooks, ERC-777-style tokens) | `nonReentrant` on `fund`/`withdraw`; CEI ordering; all other state transitions make no external calls (pull payments) |
| Fee-on-transfer / deflationary tokens | balance-delta check in `fund` reverts; prevents insolvency |
| Rebasing tokens | unsupported; negative rebase could cause insolvency for last withdrawer — UI must allowlist |
| Griefing by client (never approves) | provider `claimAfterReview` |
| Griefing by client (dispute spam) | dispute is one-shot; arbiter-timeout default pays Submitted work |
| Griefing by provider (never delivers) | client `refundExpired` after deadline |
| Griefing via reverting recipient | pull payments isolate each party |
| Gas DoS on loops | ≤ 50 milestones per escrow |
| Arbiter collusion | arbiter can only split between client and provider (never to itself or third parties); parties pick the arbiter; fallback if arbiter disappears. A colluding arbiter can still award 100% to one side — residual trust, inherent to arbitration |
| Timeout abuse: provider submits junk right before review expiry / client lets review expire | client must act inside the review window (approve or dispute); review period chosen at creation; dispute freezes the claim |
| Timeout abuse: client waits for deadline to refund delivered work | refundExpired only touches **Pending**; Submitted work remains claimable |
| Signature replay | EIP-712 domain + single-use via state + `sigDeadline` |
| Malicious ERC-1271 wallet returning true | only the client's own wallet is consulted; a client can always approve directly anyway |
| Owner abuse | owner can only change future fee (≤5%) and recipient; no pause, no sweep, no upgrade |
| Timestamp manipulation | all windows ≥ 1 hour, so validator drift (seconds) is irrelevant |

## 10. ERC-4337 / smart account integration (future)
Design rules already honoured by the contract:
1. **No `tx.origin`, no EOA assumptions**: authorization is `msg.sender` only, so a 4337 account
   executing a `UserOperation` (or a Safe/Kernel/Nexus) acts as client/provider/arbiter natively.
2. **ERC-1271 approvals**: `approveMilestoneWithSig` uses `SignatureChecker`, so a smart-account
   client can sign approvals with its own validation logic (multisig, passkey/P-256, session keys).
   Recommended: accounts wrap the digest with ERC-7739 for replay-safe nested typed data.
3. **Batching**: no function relies on being the only call in a tx. `createEscrow + fund`, or
   `approve + withdraw`, can be batched by the account (`executeBatch`) or via the escrow's built-in
   `multicall` (non-payable; ETH funding must be a direct call or account batch).
4. **Gas sponsorship**: signed approvals can be relayed by a paymaster-backed bundler or any relayer.
5. **Module surface**: `IEscrowModule` (src/interfaces) is the thin, stable interface a
   **ERC-7579 executor module** can target. Sketch:
   ```
   EscrowExecutor (module type 2) installed on account A:
     onInstall(data): store policy (max amount per milestone, allowed providers, auto-approve rules)
     autoRelease(escrowId, idx): checks policy, then
        IERC7579Execution(A).executeFromExecutor(mode, abi.encodePacked(escrow, 0, approveMilestone(...)))
   ```
   Because the escrow sees `msg.sender == A`, no escrow change is needed to support executors,
   hooks, or session-key validators. A future version may add `withdrawTo(token, recipient)` so an
   executor can sweep proceeds directly into a vault.
