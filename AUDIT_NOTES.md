# Audit notes

Tooling: Slither 0.11.6 (`slither src/MilestoneEscrow.sol --filter-paths "lib/|test/"`), forge lint,
Foundry unit/fuzz/invariant tests (100% line/statement/branch/function coverage on `src/`).

## Slither — initial run: 13 results
| Detector | Count | Resolution |
|---|---|---|
| unindexed-event-address (`FeeUpdated`) | 1 | **Fixed** — `feeRecipient` indexed |
| uninitialized-local (`refund`, `total`, `toProvider`, `toClient`) | 5 | **Fixed** — explicit `= 0` (Solidity zero-inits; cosmetic) |
| uninitialized-state (`_milestones`) | 1 | **False positive** — populated via `storage` pointer `.push()` in `createEscrow` |
| timestamp | 5 | **Accepted** — all windows ≥ 1 hour (sig deadline is user-chosen); seconds of validator drift are irrelevant |
| low-level-calls (`withdraw` ETH send) | 1 | **Accepted** — required to forward all gas to smart-account recipients; guarded by `nonReentrant`, CEI, return value checked |

## Slither — final run: 7 results, all accepted/false-positive as above. Raw: `slither-report.txt`.

## Manual review notes
* Reentrancy: only `fund` (token pull) and `withdraw` make external calls; both `nonReentrant` and CEI. Test `test_withdraw_reentrancyBlocked`.
* `fund` updates state before the external call; any revert (including FoT check) rolls back.
* `approveMilestoneWithSig` calls `isValidSignature` on the client (staticcall via OZ) — view only, no reentrancy surface.
* `Multicall` is non-payable delegatecall-to-self, so no `msg.value` double-spend.
* Rounding: fee rounds down (favours provider); dispute split rounds provider down / client gets remainder; sum always equals the unsettled amount (fuzzed).
* Residual trust: arbiter can award 100% to one side; owner can set fee up to 5% on future escrows.
* Rebasing / blocklisting tokens (USDC blacklist): a blocklisted recipient cannot withdraw; their credit is stuck but no one else is affected. Consider `withdrawTo`.
