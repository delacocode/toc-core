# TOC System Documentation

**Version:** 1.0
**Last Updated:** November 2025
**License:** BUSL-1.1

---

## Overview

The TOC (Truth On Chain) system is a modular "Truth on Chain" infrastructure for creating, resolving, and disputing verifiable predictions. It separates the lifecycle management of predictions from their resolution logic, enabling pluggable resolvers for different data sources and question types.

### Key Features

- **Multi-Answer Type Support**: Boolean, Numeric (int256), and Generic (bytes) answers
- **Pluggable Resolver Architecture**: Domain-specific resolution logic in separate contracts
- **Dual Resolver System**: System (official) and Public (third-party) resolvers
- **Bond-Backed Dispute Mechanism**: Economic security through resolution and dispute bonds
- **Template-Based Creation**: Resolvers define reusable question templates

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      TOCRegistry                             │
│  - Manages TOC lifecycle                                     │
│  - Routes to resolvers                                       │
│  - Handles disputes                                          │
│  - Stores typed results                                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
┌──────────────────┐ ┌──────────────┐ ┌──────────────┐
│ PythPriceResolver│ │ SportResolver│ │ CustomResolver│
│ (Price feeds)    │ │ (Games)      │ │ (Any data)    │
└──────────────────┘ └──────────────┘ └──────────────┘
```

---

## Core Contracts

### 1. TOCRegistry.sol

The central contract managing all TOCs. Responsibilities:

- **Resolver Management**: Register, deprecate, restore resolvers
- **TOC Lifecycle**: Create, resolve, finalize, dispute, cancel
- **Bond Management**: Accept, hold, return, slash bonds
- **Result Storage**: Typed results in separate mappings for gas efficiency

### 2. TOCTypes.sol

Shared type definitions:

```solidity
// TOC States
enum TOCState {
    NONE,           // Default/uninitialized
    PENDING,        // Awaiting resolver approval
    REJECTED,       // Resolver rejected
    ACTIVE,         // Markets can trade
    RESOLVING,      // Outcome proposed, dispute window open
    DISPUTED,       // Under admin review
    RESOLVED,       // Final outcome set
    CANCELLED       // Admin cancelled
}

// Answer Types
enum AnswerType {
    NONE,       // Default/uninitialized
    BOOLEAN,    // True/False answer
    NUMERIC,    // int256 answer
    GENERIC     // bytes answer
}

// Resolver Types
enum ResolverType {
    NONE,       // Default/unregistered
    SYSTEM,     // Official ecosystem resolvers
    PUBLIC,     // Third-party resolvers
    DEPRECATED  // Soft-deprecated (existing TOCs work, no new ones)
}

// Core TOC Structure
struct TOC {
    address resolver;           // Managing resolver
    TOCState state;             // Current state
    AnswerType answerType;      // Type of answer
    uint256 resolutionTime;     // When resolved
    uint256 disputeDeadline;    // Dispute window end
}

// Typed Result (stored separately from TOC)
struct TOCResult {
    AnswerType answerType;
    bool isResolved;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;
}
```

### 3. ITOCResolver.sol

Interface that all resolvers must implement:

```solidity
interface ITOCResolver {
    // Check if resolver manages a TOC
    function isTocManaged(uint256 tocId) external view returns (bool);

    // Called on TOC creation - returns initial state
    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (TOCState initialState);

    // Execute resolution - returns typed result
    function resolveToc(
        uint256 tocId,
        address caller,
        bytes calldata payload
    ) external returns (
        bool booleanResult,
        int256 numericResult,
        bytes memory genericResult
    );

    // Get stored TOC details
    function getTocDetails(uint256 tocId)
        external view returns (uint32 templateId, bytes memory creationPayload);

    // Generate human-readable question
    function getTocQuestion(uint256 tocId)
        external view returns (string memory question);

    // Template management
    function getTemplateCount() external view returns (uint32 count);
    function isValidTemplate(uint32 templateId) external view returns (bool);
    function getTemplateAnswerType(uint32 templateId) external view returns (AnswerType);
}
```

### 4. ITOCRegistry.sol

Registry interface for external interactions. See full interface in the contract file.

---

## TOC Lifecycle

### State Transitions

```
   CREATE
     │
     ▼
 ┌────────┐    reject    ┌──────────┐
 │PENDING │──────────────►│ REJECTED │
 └────┬───┘              └──────────┘
      │ approve
      ▼
 ┌────────┐
 │ ACTIVE │◄─────────────────────────┐
 └────┬───┘                          │
      │ propose resolution           │
      ▼                              │
 ┌───────────┐    finalize (no dispute)
 │ RESOLVING │───────────────────────┼──► RESOLVED
 └─────┬─────┘                       │
       │ dispute                     │
       ▼                             │
 ┌──────────┐    reject dispute      │
 │ DISPUTED │────────────────────────┘
 └─────┬────┘
       │ uphold dispute
       ▼
  ┌──────────┐
  │ RESOLVED │ (with flipped outcome for boolean)
  └──────────┘
       │ cancel
       ▼
  ┌───────────┐
  │ CANCELLED │
  └───────────┘
```

### 1. Creation

```solidity
// Using system resolver
uint256 tocId = registry.createTOCWithSystemResolver(
    resolverId,     // Which resolver
    templateId,     // Template within resolver
    payload         // Template-specific parameters
);

// Using public resolver
uint256 tocId = registry.createTOCWithPublicResolver(
    resolverId,
    templateId,
    payload
);
```

The resolver's `onTocCreated` is called, which:
- Validates the payload
- Stores template-specific data
- Returns initial state (PENDING or ACTIVE)

### 2. Resolution

Anyone can propose a resolution by posting a bond:

```solidity
registry.resolveTOC(
    tocId,
    bondToken,      // ERC20 or address(0) for native
    bondAmount,     // Amount to stake
    payload         // Resolver-specific proof data
);
```

The resolver's `resolveToc` returns the typed outcome:
- `booleanResult` - for BOOLEAN answer type
- `numericResult` - for NUMERIC answer type
- `genericResult` - for GENERIC answer type

### 3. Dispute Window

After resolution is proposed, a dispute window opens (default 24 hours). During this window, anyone can dispute by posting a bond:

```solidity
registry.dispute(
    tocId,
    bondToken,
    bondAmount,
    "Reason for dispute"
);
```

### 4. Finalization

If no dispute during the window:

```solidity
registry.finalizeTOC(tocId);
```

The resolution bond is returned and the result is stored.

### 5. Dispute Resolution (Admin)

If disputed, admin resolves with one of:

```solidity
registry.resolveDispute(tocId, DisputeResolution.UPHOLD_DISPUTE);
// Disputer was right - for BOOLEAN, flips the outcome
// Resolution bond slashed, dispute bond returned

registry.resolveDispute(tocId, DisputeResolution.REJECT_DISPUTE);
// Original outcome stands
// Dispute bond slashed, resolution bond returned

registry.resolveDispute(tocId, DisputeResolution.CANCEL_TOC);
// Entire TOC invalid - both bonds returned
```

---

## Answer Types

### BOOLEAN

Simple true/false answers. Example: "Will BTC be above $100,000 on Jan 1, 2026?"

```solidity
// Get result
bool result = registry.getBooleanResult(tocId);
```

### NUMERIC

Integer answers (int256 supports negative). Example: "What will BTC price be on Jan 1, 2026?"

```solidity
// Get result
int256 result = registry.getNumericResult(tocId);
```

### GENERIC

Arbitrary bytes data. Example: "What will be the winning lottery numbers?"

```solidity
// Get result
bytes memory result = registry.getGenericResult(tocId);
```

---

## Resolver System

### System Resolvers

Official, vetted resolvers trusted by the ecosystem:
- Lower dispute requirements
- Shorter dispute windows possible
- Registered by admin only

### Public Resolvers

Third-party resolvers:
- Higher bond requirements possible
- Longer dispute windows possible
- Can be registered by admin after review

### Resolver Configuration

```solidity
struct SystemResolverConfig {
    uint256 disputeWindow;      // Custom dispute period (0 = default)
    bool isActive;              // Can create new TOCs
    uint256 registeredAt;
    address registeredBy;
}

struct PublicResolverConfig {
    uint256 disputeWindow;
    bool isActive;
    uint256 registeredAt;
    address registeredBy;
}
```

### Deprecation

Resolvers can be soft-deprecated:
- Existing TOCs continue to work
- No new TOCs can be created
- Can be restored to any type later

---

## Bond System

### Resolution Bonds

- Posted when proposing resolution
- Held during dispute window
- Returned if finalized without dispute
- Slashed if dispute is upheld

### Dispute Bonds

- Required to file a dispute
- Returned if dispute is upheld
- Slashed if dispute is rejected

### Multi-Token Support

```solidity
// Admin configures acceptable bonds
registry.addAcceptableResolutionBond(tokenAddress, minAmount);
registry.addAcceptableDisputeBond(tokenAddress, minAmount);

// Use address(0) for native ETH
registry.addAcceptableResolutionBond(address(0), 0.1 ether);
```

---

## Example Resolver: PythPriceResolver

Reference implementation for price-based predictions using Pyth Network oracle.

### Templates

**Template 0: Snapshot**
```
"Will [ASSET] be ABOVE/BELOW [PRICE] at [TIME]?"
```
- Resolve at deadline only
- Answer type: BOOLEAN

**Template 1: Range**
```
"Will [ASSET] be between [MIN] and [MAX] at [TIME]?"
```
- Resolve at deadline only
- Answer type: BOOLEAN

**Template 2: Reached By**
```
"Will [ASSET] reach ABOVE/BELOW [PRICE] by [TIME]?"
```
- Can resolve early if condition met
- Answer type: BOOLEAN

### Creating a TOC

```solidity
// Encode payload for Template 0 (Snapshot)
bytes memory payload = abi.encode(
    priceId,        // bytes32 Pyth price feed ID
    threshold,      // int64 price threshold
    isAbove,        // bool - above or below
    deadline        // uint256 timestamp
);

// Create TOC
uint256 tocId = registry.createTOCWithSystemResolver(
    pythResolverId,
    0,              // Template 0
    payload
);
```

### Resolving with Pyth Data

```solidity
// Get Pyth update data (off-chain)
bytes[] memory updateData = getPythUpdateData();
bytes memory pythPayload = abi.encode(updateData);

// Propose resolution
registry.resolveTOC{value: pythFee}(
    tocId,
    address(0),     // Native ETH bond
    0.1 ether,
    pythPayload
);
```

---

## Creating a Custom Resolver

### Step 1: Implement ITOCResolver

```solidity
contract MyResolver is ITOCResolver {
    ITOCRegistry public immutable registry;

    // Template definitions
    uint32 public constant TEMPLATE_MY_QUESTION = 0;

    // Storage for TOC data
    mapping(uint256 => MyTocData) private _tocData;

    modifier onlyRegistry() {
        require(msg.sender == address(registry));
        _;
    }

    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (TOCState) {
        // Decode and validate payload
        // Store TOC-specific data
        // Return ACTIVE (or PENDING if approval needed)
        return TOCState.ACTIVE;
    }

    function resolveToc(
        uint256 tocId,
        address caller,
        bytes calldata payload
    ) external onlyRegistry returns (bool, int256, bytes memory) {
        // Verify conditions are met
        // Compute result from data source
        // Return typed result based on template's answer type

        if (getTemplateAnswerType(templateId) == AnswerType.BOOLEAN) {
            return (boolResult, 0, "");
        } else if (answerType == AnswerType.NUMERIC) {
            return (false, numResult, "");
        } else {
            return (false, 0, genericResult);
        }
    }

    function getTemplateAnswerType(uint32 templateId)
        external pure returns (AnswerType)
    {
        if (templateId == TEMPLATE_MY_QUESTION) {
            return AnswerType.BOOLEAN;
        }
        return AnswerType.NONE;
    }

    // ... implement other required functions
}
```

### Step 2: Register with TOCRegistry

```solidity
// Admin registers the resolver
registry.registerResolver(
    ResolverType.SYSTEM,  // or PUBLIC
    resolverAddress
);
```

---

## Security Considerations

### Access Control

- Admin-only: resolver registration, dispute resolution, bond configuration
- Resolver-only: approve/reject PENDING TOCs
- Anyone: create TOCs, propose resolutions, dispute

### Reentrancy Protection

All state-changing functions use `ReentrancyGuard`.

### Bond Security

- Bonds held in registry during dispute window
- Slashed bonds stay in contract (admin can withdraw)
- Pull pattern for bond returns

### Validation

- State machine enforces valid transitions
- Timing checks for dispute windows
- Bond amount validation against minimums

---

## Gas Optimization

### Separate Result Storage

Results stored in type-specific mappings to avoid loading unused fields:

```solidity
mapping(uint256 => bool) private _booleanResults;
mapping(uint256 => int256) private _numericResults;
mapping(uint256 => bytes) private _genericResults;
```

### Efficient Resolver Lookups

EnumerableSet for resolver management with O(1) lookups.

---

## Events

### Resolver Management

```solidity
event ResolverRegistered(address resolver, ResolverType resolverType, uint256 resolverId);
event ResolverDeprecated(address resolver, ResolverType resolverType);
event ResolverRestored(address resolver, ResolverType fromType, ResolverType newType);
```

### TOC Lifecycle

```solidity
event TOCCreated(uint256 tocId, ResolverType resolverType, uint256 resolverId, address resolver, uint32 templateId, AnswerType answerType, TOCState initialState);
event TOCApproved(uint256 tocId);
event TOCRejected(uint256 tocId, string reason);
event TOCResolutionProposed(uint256 tocId, address proposer, AnswerType answerType, uint256 disputeDeadline);
event TOCFinalized(uint256 tocId, AnswerType answerType);
event TOCResolved(uint256 tocId, AnswerType answerType);
event TOCCancelled(uint256 tocId, string reason);
```

### Disputes

```solidity
event TOCDisputed(uint256 tocId, address disputer, string reason);
event DisputeResolved(uint256 tocId, DisputeResolution resolution, address admin);
```

### Bonds

```solidity
event ResolutionBondDeposited(uint256 tocId, address proposer, address token, uint256 amount);
event ResolutionBondReturned(uint256 tocId, address to, address token, uint256 amount);
event DisputeBondDeposited(uint256 tocId, address disputer, address token, uint256 amount);
event DisputeBondReturned(uint256 tocId, address to, address token, uint256 amount);
event BondSlashed(uint256 tocId, address from, address token, uint256 amount);
```

---

## File Structure

```
contracts/
├── TOCRegistry/
│   ├── TOCTypes.sol          # Shared type definitions
│   ├── ITOCResolver.sol      # Resolver interface
│   ├── ITOCRegistry.sol      # Registry interface
│   └── TOCRegistry.sol       # Main registry implementation
├── resolvers/
│   └── PythPriceResolver.sol # Example resolver
└── mocks/
    └── MockResolver.sol      # Test resolver
```

---

## Development Checklist

When setting up the new repo:

1. **Dependencies**
   - OpenZeppelin Contracts (Ownable, ReentrancyGuard, SafeERC20, EnumerableSet)
   - Solidity ^0.8.29

2. **For Pyth Resolver**
   - @pythnetwork/pyth-sdk-solidity

3. **Testing**
   - Hardhat or Foundry
   - Test all state transitions
   - Test bond flows (deposit, return, slash)
   - Test dispute scenarios
   - Test each answer type

4. **Deployment**
   - Deploy TOCRegistry first
   - Deploy resolvers with registry address
   - Register resolvers
   - Configure acceptable bonds

---

## Enum First Value Convention

**IMPORTANT**: All enums in this system use `NONE` as the first value (index 0). This ensures:
- Default/uninitialized values are explicitly "none"
- No accidental interpretation of unset values
- Consistent pattern across all enums

```solidity
enum TOCState { NONE, PENDING, ... }
enum AnswerType { NONE, BOOLEAN, NUMERIC, GENERIC }
enum ResolverType { NONE, SYSTEM, PUBLIC, DEPRECATED }
enum DisputeResolution { UPHOLD_DISPUTE, ... }  // Exception: no NONE needed for actions
```

---

## Contact & Support

This documentation is for agents and developers working with the TOC system. For questions about implementation details, refer to the source code comments and NatSpec documentation.
