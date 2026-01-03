# System Architecture

Truth on Chain (TOC) is a modular infrastructure layer for creating, resolving, and disputing verifiable predictions on-chain.

## Core Value Proposition

Traditional oracles answer: "What is the price of ETH?"

TOC answers: "What is the truth, who vouches for it, and how much financial security backs the claim?"

Every answer in TOC carries:
- The result itself (boolean, numeric, or arbitrary bytes)
- An accountability tier (SYSTEM, TK_GUARANTEED, or PERMISSIONLESS)
- A resolution history (original answer, disputes, corrections)
- Financial backing (bonds posted by proposers and disputants)

## Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Consumer Protocols                      │
│         (Prediction Markets, Insurance, Derivatives)         │
└─────────────────────────────┬───────────────────────────────┘
                              │ getResult() / getExtensiveResult()
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        TruthEngine                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Resolver  │  │     TOC     │  │      Dispute        │  │
│  │  Management │  │  Lifecycle  │  │     Resolution      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │    Bond     │  │   Result    │  │    TruthKeeper      │  │
│  │   System    │  │   Storage   │  │     Management      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────┬───────────────────────────────┘
                              │ onTocCreated() / resolveToc()
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         Resolvers                            │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐    │
│  │ PythPrice     │  │  Optimistic   │  │    Custom     │    │
│  │ Resolver      │  │   Resolver    │  │   Resolver    │    │
│  └───────────────┘  └───────────────┘  └───────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Key Storage Structures

```solidity
// Resolver trust levels
mapping(address => ResolverConfig) _resolverConfigs;

// All registered resolvers
EnumerableSet.AddressSet _registeredResolvers;

// TOC state machines
mapping(uint256 => TOC) _tocs;

// Unified result storage (ABI-encoded bytes)
mapping(uint256 => bytes) _results;

// Round 1 dispute information
mapping(uint256 => DisputeInfo) _disputes;

// Round 2 escalation information
mapping(uint256 => EscalationInfo) _escalations;

// TruthKeeper guaranteed resolvers
mapping(address => EnumerableSet.AddressSet) _tkGuaranteedResolvers;
```

## Architecture Sections

- [Core Concepts](core-concepts.md) - TOCs, Resolvers, TruthKeepers, and Accountability Tiers
- [TOC Lifecycle](toc-lifecycle.md) - State machine and lifecycle phases
- [Resolver System](resolver-system.md) - Interface, answer types, and examples
- [Dispute Resolution](dispute-resolution.md) - Two-round dispute system
- [Accountability Model](accountability-model.md) - Tier calculation and usage
- [Bond Economics](bond-economics.md) - Incentive design
- [Result Storage](result-storage.md) - Unified bytes approach
- [Design Decisions](design-decisions.md) - Trade-offs and rationale
