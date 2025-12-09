# Bond Economics

## Purpose

Bonds create economic incentives for honest behavior:

- **Proposers** stake capital behind their answers
- **Disputers** stake capital to challenge
- **Losers** get slashed → discourages frivolous participation
- **Winners** get paid → rewards truth-seeking

## Bond Flow

### Resolution Bond (posted by proposer)

| Outcome | Proposer's Bond |
|---------|-----------------|
| No dispute | Returned in full |
| Dispute rejected | Returned in full |
| Dispute upheld | 50% to disputer, 50% to protocol |
| POP cancelled | Returned in full |

### Dispute Bond (posted by disputer)

| Outcome | Disputer's Bond |
|---------|-----------------|
| Dispute upheld | Returned in full |
| Dispute rejected | 50% to proposer, 50% to protocol |
| POP cancelled | Returned in full |

### Escalation Bond (Round 2)

| Outcome | Challenger's Bond |
|---------|-------------------|
| Challenge succeeds | Returned + 50% of opponent's Round 1 winnings |
| Challenge fails | 50% to opponent, 50% to protocol |

## The 50/50 Split

Why split slashed bonds between winner and protocol?

- **Winner incentive**: rewards truth-seeking
- **Protocol incentive**: sustains the system, prevents collusion
