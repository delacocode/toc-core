# Core Concepts

## POP (Prediction Option Protocol)

A POP is the fundamental unit in TOC. It represents a question that will be resolved to an answer.

### Anatomy of a POP

- **Resolver** - The contract responsible for determining the answer
- **Template** - A reusable question format defined by the resolver
- **Payload** - Question-specific parameters (e.g., asset, threshold, deadline)
- **TruthKeeper** - The domain expert assigned to adjudicate disputes
- **Time windows** - Configurable periods for disputes, escalation, and correction
- **Accountability tier** - Immutable snapshot of trust level at creation

## Resolvers

Resolvers are pluggable contracts that handle domain-specific resolution logic. The registry doesn't care how a resolver determines truth - it only cares that the resolver implements the standard interface.

### Examples

- **PythPriceResolver** - Pulls price data from Pyth oracles
- **OptimisticResolver** - Accepts human-submitted answers with dispute protection
- **Custom resolvers** - Any logic you need (API data, on-chain state, voting, etc.)

## TruthKeepers

TruthKeepers are whitelisted addresses with domain expertise. They:

- Get assigned to POPs at creation time
- Adjudicate Round 1 disputes
- Can declare which resolvers they guarantee (affecting accountability tier)
- Face timeout penalties if they fail to act

## Accountability Tiers

Every POP has an immutable accountability tier captured at creation:

| Tier | Derivation | Meaning |
|------|------------|---------|
| **SYSTEM** | SYSTEM resolver + whitelisted TruthKeeper | Maximum protocol backing |
| **TK_GUARANTEED** | TruthKeeper has guaranteed this resolver | TruthKeeper stakes reputation |
| **PERMISSIONLESS** | Everything else | Consumer assumes risk |
