# Pitch Deck

## The Problem

- **Oracles give you data. But who's accountable when it's wrong?**
- Prediction markets resolve one question type. What about everything else?
- Every protocol building truth resolution reinvents the wheel
- No standard way to know: "How much financial security backs this answer?"

## The Reality Today

- Oracle fails → Protocol eats the loss → Users lose trust
- Custom resolution logic → Audit burden → Security surface
- Binary YES/NO only → Can't express "the price was $47,231"
- One-size-fits-all trust → Can't match security to use case

## The Solution: Truth on Chain

**A new DeFi primitive: pluggable truth resolution with quantifiable accountability**

- Any question type (boolean, numeric, arbitrary data)
- Any data source (oracles, humans, on-chain state, APIs)
- Any resolution method (instant, optimistic, multi-round dispute)
- Known financial backing for every answer

## How It Works

- **You ask** → "Did ETH hit $5k before Dec 31?"
- **Resolver answers** → Pulls from Pyth, submits result
- **Dispute window** → Anyone can challenge with a bond
- **Result finalizes** → With known accountability tier attached

Your protocol just calls `getResult()`. We handle the rest.

## Three Accountability Tiers

| Tier | Backing | Best For |
|------|---------|----------|
| **SYSTEM** | Protocol-backed, maximum security | High-value settlements, institutional use |
| **TK_GUARANTEED** | TruthKeeper-backed, balanced | Most production use cases |
| **PERMISSIONLESS** | Community-backed, maximum flexibility | Experiments, long-tail questions |

**You choose your risk/reward. We make it transparent.**

## Why TOC is Different

- **Not an oracle** → We don't provide data. We resolve truth from any source.
- **Not a prediction market** → We're infrastructure. Markets build on us.
- **Not one-size-fits-all** → Match security level to your use case.

## Pluggable Resolver Architecture

```
┌─────────────────────────────────────────────────┐
│                  Your Protocol                   │
│              (just call getResult)               │
└─────────────────────┬───────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────┐
│                 TOC Registry                     │
│    State Machine • Bonds • Disputes • Results    │
└─────────────────────┬───────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
   ┌─────────┐   ┌─────────┐   ┌─────────┐
   │  Pyth   │   │ Sports  │   │  Your   │
   │ Prices  │   │ Events  │   │ Custom  │
   └─────────┘   └─────────┘   └─────────┘

**Add new resolvers. Zero registry changes.**
```

## Two-Round Dispute System

1. **Resolution proposed** → Proposer stakes bond
2. **Dispute window** → Anyone can challenge (higher bond)
3. **Round 1: TruthKeeper** → Domain expert reviews
4. **Round 2: Escalation** → Admin/community final decision

**Liars get slashed. Truth wins and gets paid.**

## Use Cases

### Price Predictions
"Will BTC exceed $100k by Dec 31?"
→ Pyth resolver, instant resolution, BOOLEAN result

### Sports & Events
"Will Lakers beat Celtics?"
→ Optimistic resolver, TruthKeeper validation, BOOLEAN result

### Numerical Outcomes
"What was ETH price at midnight UTC?"
→ Oracle resolver, NUMERIC result (int256)

### Arbitrary Data
"Who won the hackathon?"
→ Custom resolver, GENERIC result (bytes)

## Who Builds on TOC?

- **Prediction markets** → Focus on UX, we handle resolution
- **Insurance protocols** → Parametric triggers with accountability
- **Derivatives platforms** → Settlement layer with dispute protection
- **Gaming/NFT projects** → Verifiable outcomes for rewards
- **DAOs** → Objective decision inputs with known trust levels

## The Integration

```solidity
// That's it. Really.
(bytes memory result, bool finalized, AccountabilityTier tier) =
    registry.getExtensiveResult(tocId);
```

- One call to get the answer
- Know exactly what accountability backs it
- Handle your business logic

## What You Get

- **No resolution logic to build** → We handle state machines, bonds, disputes
- **No oracle integration headaches** → Resolvers abstract data sources
- **No trust assumptions hidden** → Accountability tier is explicit
- **No upgrade risk** → Add resolvers without touching the registry

## Get Started

- **Integrate** → Call the registry, consume results
- **Build a resolver** → Bring your own data source
- **Run a TruthKeeper** → Earn fees for domain expertise

**Truth on Chain. Financially backed. Transparently accountable.**
