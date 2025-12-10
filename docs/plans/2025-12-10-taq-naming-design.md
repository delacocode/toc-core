# TAQ Naming Design

**Date:** 2025-12-10
**Status:** Approved

## Decision

Rename **POP** (Prediction Option Protocol) to **TAQ** (Truthly Answered Questions).

## Rationale

"POP" implied predictions/forecasting, but the TOC system handles **any truth on chain** - not just predictions. Examples include price feeds, event outcomes, API data, on-chain state, and governance inputs.

"TAQ" better captures the system's broader purpose as truth infrastructure.

## The Name

**TAQ** = **Truthly Answered Questions**

- **Truthly** - A coined adverb unique to TOC, suggesting the manner in which questions get answered (with verifiable, accountable truth)
- **Answered** - Emphasizes that every question reaches resolution
- **Questions** - Generic enough to cover any question type, not just predictions

## Why It Works

| Aspect | Evaluation |
|--------|------------|
| **Pronounceable** | Yes - "tack" - short, memorable |
| **Novel** | "Truthly" is a coined term unique to TOC |
| **Meaningful** | Captures exactly what the system does |
| **Flexible** | Works for any question type (not just predictions) |
| **Brandable** | Distinctive, can become TOC's signature primitive |

## Usage

### Contracts

- `TAQRegistry.sol` (was `POPRegistry.sol`)
- `TAQTypes.sol` (was `POPTypes.sol`)
- `ITAQResolver.sol` (was `IPopResolver.sol`)

### Code

```solidity
uint256 taqId;
TAQState state;
createTAQ();
resolveTAQ();
finalizeTAQ();
```

### Documentation

- "Create a TAQ"
- "The TAQ was disputed"
- "TAQ lifecycle"
- "This resolver handles price TAQs"

## Definition for Docs

> **TAQ (Truthly Answered Question)**: The fundamental unit in TOC. A TAQ represents a question submitted to the system that will be resolved to a verifiable answer with explicit accountability guarantees.

## Migration Scope

The following will need renaming:

1. **Contracts**: All POP references to TAQ
2. **Interfaces**: `IPopResolver` → `ITAQResolver`
3. **Types**: `POPState` → `TAQState`, `POPResult` → `TAQResult`, etc.
4. **Events**: `POPCreated` → `TAQCreated`, etc.
5. **Documentation**: All docs referencing POP
6. **Tests**: All test files and test names

## Backward Compatibility

This is a breaking change. Since the system is pre-launch, no migration path is needed - clean rename throughout.
