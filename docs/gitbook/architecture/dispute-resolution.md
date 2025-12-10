# Dispute Resolution

## Two-Round System

### Round 1: TruthKeeper Review

```
Dispute filed → TruthKeeper assigned → Decision within window
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
              UPHOLD_DISPUTE            REJECT_DISPUTE             CANCEL_POP
              (disputer wins)           (proposer wins)           (void, refund)
```

If TruthKeeper times out → auto-escalate to Round 2.

### Round 2: Admin Escalation

Any party can challenge the Round 1 decision by posting an escalation bond (higher than Round 1 bond).

```
Escalation filed → Admin reviews → Final decision
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              UPHOLD_DISPUTE      REJECT_DISPUTE       CANCEL_POP
```

Admin decision is final.

## Decision Types

```solidity
enum DisputeResolution {
    UPHOLD_DISPUTE,   // Disputer was right, proposer wrong
    REJECT_DISPUTE,   // Proposer was right, disputer wrong
    CANCEL_TOC,       // Question invalid, void everything
    TOO_EARLY         // Cannot decide yet
}
```

## Post-Resolution Disputes

Even after RESOLVED state, if `postResolutionWindow > 0`:

- Anyone can dispute the finalized result
- Same two-round process applies
- If upheld, result is corrected (original preserved in history)
- `_hasCorrectedResult` flag tracks corrections
