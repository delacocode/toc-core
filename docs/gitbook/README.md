# Truth on Chain (TOC)

**Financially-Backed Truth Infrastructure for DeFi**

Truth on Chain (TOC) is a modular infrastructure layer for creating, resolving, and disputing verifiable predictions on-chain. The system introduces **Truth On Chain (TOC)** units - a standardized unit of truth that can be created, resolved, disputed, and consumed by any protocol.

## What Makes TOC Different

Traditional oracles answer: "What is the price of ETH?"

TOC answers: "What is the truth, who vouches for it, and how much financial security backs the claim?"

Every answer in TOC carries:
- The result itself (boolean, numeric, or arbitrary bytes)
- An accountability tier (SYSTEM, TK_GUARANTEED, or PERMISSIONLESS)
- A resolution history (original answer, disputes, corrections)
- Financial backing (bonds posted by proposers and disputants)

## Quick Links

- [Executive Summary](executive-summary.md) - High-level overview for stakeholders
- [Pitch Deck](pitch-deck.md) - Visual presentation of TOC
- [System Architecture](architecture/README.md) - Technical deep dive

## The Integration

```solidity
// That's it. Really.
(bytes memory result, bool finalized, AccountabilityTier tier) =
    registry.getExtensiveResult(tocId);
```

- One call to get the answer
- Know exactly what accountability backs it
- Handle your business logic
