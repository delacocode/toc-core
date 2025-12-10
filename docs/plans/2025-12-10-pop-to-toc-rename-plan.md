# POP to TOC Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename all POP references to TOC (Truth On Chain) throughout the codebase.

**Architecture:** Global find-and-replace across contracts, interfaces, tests, libraries, and documentation. The rename is mechanical - no logic changes, only naming.

**Tech Stack:** Solidity 0.8.29, Foundry/Hardhat testing

---

## Naming Conventions

| Old | New |
|-----|-----|
| `POP` | `TOC` |
| `Pop` | `Toc` |
| `pop` | `toc` |
| `Popregistry` (folder) | `TOCRegistry` |
| `POPRegistry` | `TOCRegistry` |
| `POPTypes` | `TOCTypes` |
| `POPResult` | `TOCResult` |
| `POPState` | `TOCState` |
| `POPInfo` | `TOCInfo` |
| `POPResultCodec` | `TOCResultCodec` |
| `IPopResolver` | `ITOCResolver` |
| `IPOPRegistry` | `ITOCRegistry` |
| `popId` | `tocId` |
| `nextPopId` | `nextTocId` |
| `_pops` | `_tocs` |

---

## Task 1: Rename POPTypes.sol to TOCTypes.sol

**Files:**
- Rename: `contracts/Popregistry/POPTypes.sol` → `contracts/TOCRegistry/TOCTypes.sol`

**Step 1: Create the TOCRegistry directory**

```bash
mkdir -p contracts/TOCRegistry
```

**Step 2: Copy POPTypes.sol to new location with new name**

```bash
cp contracts/Popregistry/POPTypes.sol contracts/TOCRegistry/TOCTypes.sol
```

**Step 3: Update file content - replace all POP references with TOC**

In `contracts/TOCRegistry/TOCTypes.sol`:
- Line 4: `/// @title TOCTypes`
- Line 5: `/// @notice Shared types for the TOC (Truth On Chain) system`
- Line 7: `/// @notice States a TOC can be in throughout its lifecycle`
- Line 8: `enum TOCState {`
- Line 20: `/// @notice Types of answers a TOC can have`
- Line 32: `CANCEL_TOC,      // Entire TOC is invalid, refund all`
- Line 44: `/// @notice Accountability tier for a TOC (snapshot at creation)`
- Line 59: `/// @notice Response from TruthKeeper when a TOC is assigned`
- Line 66: `/// @notice Core TOC data stored in registry`
- Line 67: `struct TOC {`
- Line 68: `address resolver;               // Which resolver manages this TOC`
- Line 87: `address truthKeeper;            // Assigned TruthKeeper for this TOC`
- Line 90: `/// @notice Result data for a resolved TOC`
- Line 92: `struct TOCResult {`
- Line 93: `AnswerType answerType;      // Which type of answer this TOC returns`
- Line 147: `/// @notice Extended TOC info with resolver context`
- Line 148: `struct TOCInfo {`
- Line 149: `// TOC fields`

**Step 4: Commit**

```bash
git add contracts/TOCRegistry/TOCTypes.sol
git commit -m "feat: add TOCTypes.sol - renamed from POPTypes"
```

---

## Task 2: Rename IPopResolver.sol to ITOCResolver.sol

**Files:**
- Create: `contracts/TOCRegistry/ITOCResolver.sol`

**Step 1: Copy and rename**

```bash
cp contracts/Popregistry/IPopResolver.sol contracts/TOCRegistry/ITOCResolver.sol
```

**Step 2: Update file content**

In `contracts/TOCRegistry/ITOCResolver.sol`:
- Line 4: `import "./TOCTypes.sol";`
- Line 6: `/// @title ITOCResolver`
- Line 7: `/// @notice Interface that all TOC resolvers must implement`
- Line 8-12: Update comments to say "TOC" instead of "POP"
- Line 13: `interface ITOCResolver {`
- Line 14-17: `/// @notice Check if this resolver manages a given TOC` and `function isTocManaged(uint256 tocId)`
- Line 19-29: Update all `popId` to `tocId`, update comments
- Line 25: `function onTocCreated(`
- Line 31-46: Update function `resolveToc` and all param names/comments
- Line 42: `function resolveToc(`
- Line 48-55: Update `getTocDetails` function
- Line 52: `function getTocDetails(uint256 tocId)`
- Line 57-64: Update `getTocQuestion` function
- Line 61: `function getTocQuestion(uint256 tocId)`

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/ITOCResolver.sol
git commit -m "feat: add ITOCResolver.sol - renamed from IPopResolver"
```

---

## Task 3: Rename IPOPRegistry.sol to ITOCRegistry.sol

**Files:**
- Create: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Copy and rename**

```bash
cp contracts/Popregistry/IPOPRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
```

**Step 2: Update file content**

In `contracts/TOCRegistry/ITOCRegistry.sol`:
- Line 4: `import "./TOCTypes.sol";`
- Line 6: `/// @title ITOCRegistry`
- Line 7: `/// @notice Interface for the TOC Registry contract`
- Line 8: `/// @dev Central contract managing TOC lifecycle, resolvers, and disputes`
- Line 9: `interface ITOCRegistry {`
- Replace all `POP` with `TOC` in event names:
  - `TOCCreated`, `TOCApproved`, `TOCRejected`, `TOCResolutionProposed`, `TOCResolved`, `TOCFinalized`, `TOCDisputed`, `TOCCancelled`
- Replace all `popId` with `tocId` throughout
- Replace all function names:
  - `createTOC`, `resolveTOC`, `finalizeTOC`, `approveTOC`, `rejectTOC`
  - `getTOC`, `getTOCInfo`, `getTocDetails`, `getTocQuestion`
  - `getTOCResult`, `nextTocId`
- Update all NatSpec comments

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add ITOCRegistry.sol - renamed from IPOPRegistry"
```

---

## Task 4: Copy ITruthKeeper.sol (no rename needed)

**Files:**
- Copy: `contracts/Popregistry/ITruthKeeper.sol` → `contracts/TOCRegistry/ITruthKeeper.sol`

**Step 1: Copy file**

```bash
cp contracts/Popregistry/ITruthKeeper.sol contracts/TOCRegistry/ITruthKeeper.sol
```

**Step 2: Update imports and references**

In `contracts/TOCRegistry/ITruthKeeper.sol`:
- Line 4: `import "./TOCTypes.sol";`
- Update any comments referencing POP to TOC
- Update parameter names `popId` to `tocId`

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/ITruthKeeper.sol
git commit -m "feat: copy ITruthKeeper.sol to TOCRegistry with updated references"
```

---

## Task 5: Rename POPRegistry.sol to TOCRegistry.sol

**Files:**
- Create: `contracts/TOCRegistry/TOCRegistry.sol`

**Step 1: Copy and rename**

```bash
cp contracts/Popregistry/POPRegistry.sol contracts/TOCRegistry/TOCRegistry.sol
```

**Step 2: Update imports**

```solidity
import "./TOCTypes.sol";
import "./ITOCRegistry.sol";
import "./ITOCResolver.sol";
import "./ITruthKeeper.sol";
```

**Step 3: Update contract declaration and all internal references**

- Line 15: `/// @title TOCRegistry`
- Line 16: `/// @notice Central registry managing TOC lifecycle, resolvers, and disputes`
- Line 17: `/// @dev Implementation of ITOCRegistry with unified resolver trust system`
- Line 18: `contract TOCRegistry is ITOCRegistry, ReentrancyGuard, Ownable {`
- Replace all internal mappings/variables:
  - `_pops` → `_tocs`
  - `_nextPopId` → `_nextTocId`
- Replace all function parameter names `popId` → `tocId`
- Replace all struct references `POP` → `TOC`
- Replace all state references `POPState` → `TOCState`
- Replace all error names containing POP
- Update all event emissions
- Update all NatSpec comments

**Step 4: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol
git commit -m "feat: add TOCRegistry.sol - renamed from POPRegistry"
```

---

## Task 6: Rename POPResultCodec.sol to TOCResultCodec.sol

**Files:**
- Rename: `contracts/libraries/POPResultCodec.sol` → `contracts/libraries/TOCResultCodec.sol`

**Step 1: Rename file**

```bash
mv contracts/libraries/POPResultCodec.sol contracts/libraries/TOCResultCodec.sol
```

**Step 2: Update content**

In `contracts/libraries/TOCResultCodec.sol`:
- Line 4: `/// @title TOCResultCodec`
- Line 5: `/// @notice Encoding/decoding utilities for TOC results`
- Line 8: `library TOCResultCodec {`

**Step 3: Commit**

```bash
git add contracts/libraries/
git commit -m "feat: rename POPResultCodec to TOCResultCodec"
```

---

## Task 7: Update OptimisticResolver.sol

**Files:**
- Modify: `contracts/resolvers/OptimisticResolver.sol`

**Step 1: Update imports**

```solidity
import "../TOCRegistry/ITOCResolver.sol";
import "../TOCRegistry/ITOCRegistry.sol";
import "../TOCRegistry/TOCTypes.sol";
import "../libraries/TOCResultCodec.sol";
```

**Step 2: Update interface implementation**

- Line 15: `contract OptimisticResolver is ITOCResolver {`

**Step 3: Update all internal references**

- Replace `popId` with `tocId` in all functions
- Replace `IPopResolver` references
- Replace `IPOPRegistry` with `ITOCRegistry`
- Replace `POPState` with `TOCState`
- Replace `POPResultCodec` with `TOCResultCodec`
- Rename functions: `isPopManaged` → `isTocManaged`, `onPopCreated` → `onTocCreated`, etc.
- Update all NatSpec comments

**Step 4: Commit**

```bash
git add contracts/resolvers/OptimisticResolver.sol
git commit -m "refactor: update OptimisticResolver to use TOC naming"
```

---

## Task 8: Update PythPriceResolver.sol

**Files:**
- Modify: `contracts/resolvers/PythPriceResolver.sol`

**Step 1: Update imports**

```solidity
import "../TOCRegistry/ITOCResolver.sol";
import "../TOCRegistry/ITOCRegistry.sol";
import "../TOCRegistry/TOCTypes.sol";
import "../libraries/TOCResultCodec.sol";
```

**Step 2: Update all references** (same pattern as OptimisticResolver)

**Step 3: Commit**

```bash
git add contracts/resolvers/PythPriceResolver.sol
git commit -m "refactor: update PythPriceResolver to use TOC naming"
```

---

## Task 9: Update MockResolver.sol

**Files:**
- Modify: `contracts/test/MockResolver.sol`

**Step 1: Update imports and implementation**

Same pattern as other resolvers - update imports, interface, function names, parameter names.

**Step 2: Commit**

```bash
git add contracts/test/MockResolver.sol
git commit -m "refactor: update MockResolver to use TOC naming"
```

---

## Task 10: Update MockTruthKeeper.sol

**Files:**
- Modify: `contracts/test/MockTruthKeeper.sol`

**Step 1: Update imports**

```solidity
import "../TOCRegistry/TOCTypes.sol";
import "../TOCRegistry/ITruthKeeper.sol";
```

**Step 2: Update parameter names**

Replace `popId` with `tocId` throughout.

**Step 3: Commit**

```bash
git add contracts/test/MockTruthKeeper.sol
git commit -m "refactor: update MockTruthKeeper to use TOC naming"
```

---

## Task 11: Update ConfigurableTruthKeeper.sol

**Files:**
- Modify: `contracts/examples/ConfigurableTruthKeeper.sol`

**Step 1: Update imports and references** (same pattern as MockTruthKeeper)

**Step 2: Commit**

```bash
git add contracts/examples/ConfigurableTruthKeeper.sol
git commit -m "refactor: update ConfigurableTruthKeeper to use TOC naming"
```

---

## Task 12: Rename and update POPRegistry.t.sol

**Files:**
- Rename: `contracts/test/POPRegistry.t.sol` → `contracts/test/TOCRegistry.t.sol`

**Step 1: Rename file**

```bash
mv contracts/test/POPRegistry.t.sol contracts/test/TOCRegistry.t.sol
```

**Step 2: Update imports**

```solidity
import "../TOCRegistry/TOCRegistry.sol";
import "../TOCRegistry/TOCTypes.sol";
```

**Step 3: Update all references**

- Rename test contract: `TOCRegistryTest`
- Replace all variable names and function calls

**Step 4: Commit**

```bash
git add contracts/test/
git commit -m "refactor: rename and update TOCRegistry.t.sol"
```

---

## Task 13: Update OptimisticResolver.t.sol

**Files:**
- Modify: `contracts/test/OptimisticResolver.t.sol`

**Step 1: Update imports and all TOC references**

**Step 2: Commit**

```bash
git add contracts/test/OptimisticResolver.t.sol
git commit -m "refactor: update OptimisticResolver.t.sol to use TOC naming"
```

---

## Task 14: Delete old Popregistry folder

**Files:**
- Delete: `contracts/Popregistry/` (entire folder)

**Step 1: Verify new files are working**

```bash
forge build
```

**Step 2: Remove old folder**

```bash
rm -rf contracts/Popregistry
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove old Popregistry folder"
```

---

## Task 15: Run tests to verify rename

**Step 1: Build**

```bash
forge build
```

Expected: Successful compilation

**Step 2: Run tests**

```bash
forge test
```

Expected: All tests pass

**Step 3: Fix any compilation errors**

If there are errors, they will likely be missed renames. Fix them.

---

## Task 16: Update documentation - POP_SYSTEM_DOCUMENTATION.md

**Files:**
- Rename and update: `docs/POP_SYSTEM_DOCUMENTATION.md` → `docs/TOC_SYSTEM_DOCUMENTATION.md`

**Step 1: Rename file**

```bash
mv docs/POP_SYSTEM_DOCUMENTATION.md docs/TOC_SYSTEM_DOCUMENTATION.md
```

**Step 2: Global replace**

Replace all occurrences of:
- `POP` → `TOC`
- `Pop` → `Toc`
- `pop` → `toc`
- `Prediction Option Protocol` → `Truth On Chain`
- `POPRegistry` → `TOCRegistry`
- `POPTypes` → `TOCTypes`

**Step 3: Commit**

```bash
git add docs/
git commit -m "docs: rename POP_SYSTEM_DOCUMENTATION to TOC_SYSTEM_DOCUMENTATION"
```

---

## Task 17: Update GitBook documentation

**Files:**
- Update all files in `docs/gitbook/`

**Step 1: Rename pop-lifecycle.md**

```bash
mv docs/gitbook/architecture/pop-lifecycle.md docs/gitbook/architecture/toc-lifecycle.md
```

**Step 2: Update SUMMARY.md with new path**

**Step 3: Global replace in all gitbook/*.md files**

Replace all POP/Pop/pop references with TOC/Toc/toc.

**Step 4: Commit**

```bash
git add docs/gitbook/
git commit -m "docs: update GitBook documentation with TOC naming"
```

---

## Task 18: Update remaining plan documents

**Files:**
- Update all files in `docs/plans/` that reference POP

**Step 1: Global replace in plan files**

Update references but don't rename the files (they're historical records).

**Step 2: Commit**

```bash
git add docs/plans/
git commit -m "docs: update plan documents with TOC references"
```

---

## Task 19: Final verification

**Step 1: Search for any remaining POP references**

```bash
grep -r "POP\|Pop\|pop" contracts/ --include="*.sol" | grep -v node_modules
```

Expected: No results (or only false positives like "population")

**Step 2: Search docs**

```bash
grep -r "POP\|Popregistry" docs/ --include="*.md"
```

Expected: No results (except historical references in old plan files)

**Step 3: Final build and test**

```bash
forge build && forge test
```

Expected: All pass

**Step 4: Final commit**

```bash
git add -A
git commit -m "chore: complete POP to TOC rename"
```

---

## Summary

Total tasks: 19

Key changes:
1. Folder rename: `Popregistry` → `TOCRegistry`
2. Contract renames: `POPRegistry` → `TOCRegistry`, `POPTypes` → `TOCTypes`, etc.
3. Interface renames: `IPopResolver` → `ITOCResolver`, `IPOPRegistry` → `ITOCRegistry`
4. Library rename: `POPResultCodec` → `TOCResultCodec`
5. Variable/parameter renames: `popId` → `tocId`, `_pops` → `_tocs`
6. Documentation updates throughout
