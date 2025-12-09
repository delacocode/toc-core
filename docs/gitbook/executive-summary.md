# Executive Summary

## What It Is

TOC is infrastructure for **financially-backed truth resolution** on-chain. It's a new DeFi primitive that sits between data sources and protocols, providing verifiable answers with explicit accountability guarantees.

## The Core Innovation

Every answer in TOC comes with a known **accountability tier**:

| Tier | What It Means |
|------|---------------|
| **SYSTEM** | Protocol-backed. Maximum security. Suitable for high-value settlements. |
| **TK_GUARANTEED** | TruthKeeper-backed. Balanced risk/reward. Standard production use. |
| **PERMISSIONLESS** | Community-backed. Maximum flexibility. Experimental or long-tail use. |

Consumers don't guess at trust. They see it explicitly and choose accordingly.

## The Problem

Protocols needing truth resolution today face three choices:

1. **Build it yourself** - Engineering burden, audit costs, security surface
2. **Use an oracle** - Limited to price feeds, no accountability when wrong
3. **Use a prediction market** - Only binary outcomes, not infrastructure

None provide: flexible answer types + pluggable data sources + quantifiable accountability.

## The Solution

TOC separates concerns:

- **Registry** - State machine, bonds, disputes, result storage
- **Resolvers** - Pluggable modules for any data source (oracles, humans, APIs, on-chain state)
- **TruthKeepers** - Domain experts who stake reputation on accuracy

Protocols integrate once, then access any resolver through a single interface.

## Key Differentiators

| Capability | TOC | Traditional Oracles | Prediction Markets |
|------------|-----|--------------------|--------------------|
| Answer types | Boolean, Numeric, Arbitrary | Numeric only | Binary only |
| Data sources | Any (pluggable) | Fixed providers | Platform-specific |
| Accountability | Explicit, tiered | Implicit/none | Platform bears risk |
| Extensibility | Permissionless resolvers | Vendor-dependent | Closed systems |
| Dispute resolution | Two-round escalation | None | Varies |

## Economic Model

- **Bond economics** - Proposers and disputants stake capital. Liars get slashed. Truth wins and gets paid.
- **TruthKeeper fees** - Domain experts earn for accurate adjudication
- **Protocol fees** - Configurable fee on resolution for sustainability
- **Permissionless participation** - Anyone can register resolvers, propose resolutions, or dispute

## Security Model

- Bonds scale with value at risk
- Two-round dispute prevents single points of failure
- Immutable accountability snapshots at creation time
- Post-resolution correction window for additional protection

## Target Integrators

- **Prediction markets** - Outsource resolution complexity
- **Derivatives & options** - Settlement with dispute protection
- **Insurance protocols** - Parametric claims with accountability
- **Gaming & NFTs** - Verifiable outcomes for rewards
- **DAOs** - Objective inputs for governance decisions

## Technical Readiness

- Core registry and resolver contracts complete
- Comprehensive test coverage (Foundry)
- Modular architecture proven with multiple resolver types
- L2-first deployment target (Arbitrum, Optimism, Base)

## Summary

TOC introduces **financially-backed truth** as a DeFi primitive:

- **Flexible** - Any question type, any data source, any resolution method
- **Transparent** - Accountability tier explicit for every answer
- **Simple** - One integration, access all resolvers
- **Secure** - Economic incentives align around truth

**Truth on Chain. Quantifiable accountability. Infrastructure for what comes next.**
