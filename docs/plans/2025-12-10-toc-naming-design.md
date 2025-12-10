# TOC Naming Design

**Date:** 2025-12-10
**Status:** Approved

## Decision

Rename **POP** (Prediction Option Protocol) to **TOC** (Truth On Chain).

## Rationale

"POP" implied predictions/forecasting, but the system handles **any truth on chain** - not just predictions. Examples include price feeds, event outcomes, API data, on-chain state, and governance inputs.

Using "TOC" for the fundamental unit creates elegant self-reference: the TOC system manages TOCs (individual truths on chain).

## The Name

**TOC** = **Truth On Chain**

- **Truth** - The core purpose of the system
- **On Chain** - Where it lives and is verified
- **Self-referential** - The TOC system manages TOCs

## Why It Works

| Aspect | Evaluation |
|--------|------------|
| **Pronounceable** | Yes - "tock" - short, memorable |
| **Simple** | No invented words, immediately understood |
| **Meaningful** | Exactly describes what it is |
| **Flexible** | Works for any question type |
| **Brandable** | System and primitive share identity |

## Usage

### Contracts

- `TOCRegistry.sol` (was `POPRegistry.sol`)
- `TOCTypes.sol` (was `POPTypes.sol`)
- `ITOCResolver.sol` (was `IPopResolver.sol`)

### Code

```solidity
uint256 tocId;
TOCState state;
createTOC();
resolveTOC();
finalizeTOC();
```

### Documentation

- "Create a TOC"
- "The TOC was disputed"
- "TOC lifecycle"
- "This resolver handles price TOCs"

## Definition for Docs

> **TOC (Truth On Chain)**: The fundamental unit in the TOC system. A TOC represents a question submitted to the system that will be resolved to a verifiable answer with explicit accountability guarantees.

## Migration Scope

The following will need renaming:

1. **Contracts**: All POP references to TOC
2. **Interfaces**: `IPopResolver` → `ITOCResolver`
3. **Types**: `POPState` → `TOCState`, `POPResult` → `TOCResult`, etc.
4. **Events**: `POPCreated` → `TOCCreated`, etc.
5. **Documentation**: All docs referencing POP
6. **Tests**: All test files and test names

## Backward Compatibility

This is a breaking change. Since the system is pre-launch, no migration path is needed - clean rename throughout.
