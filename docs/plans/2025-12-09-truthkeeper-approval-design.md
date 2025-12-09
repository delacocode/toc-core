# TruthKeeper Approval Mechanism

## Summary

Add an active approval layer where TruthKeeper contracts receive callbacks when POPs are created with them assigned. The TK contract decides whether to approve, soft-reject (allow as PERMISSIONLESS), or hard-reject (revert).

## Key Changes

1. **TruthKeepers must be contracts** - EOAs no longer supported
2. **Per-POP approval replaces resolver guarantees** - Remove `_tkGuaranteedResolvers`
3. **Tier calculation based on approval** - TK_GUARANTEED/SYSTEM only if TK approved
4. **New ITruthKeeper interface** - `canAcceptPop()` view + `onPopAssigned()` callback

## New Tier Logic

| Condition | Tier |
|-----------|------|
| SYSTEM resolver + whitelisted TK + TK approved | SYSTEM |
| TK approved (any other case) | TK_GUARANTEED |
| TK soft-rejected or no approval | PERMISSIONLESS |
| TK hard-rejected | Transaction reverts |

---

## ITruthKeeper Interface

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/// @notice Response from TruthKeeper when a POP is assigned
enum TKApprovalResponse {
    APPROVE,        // Accept responsibility, tier upgrades
    REJECT_SOFT,    // Decline but allow POP as PERMISSIONLESS
    REJECT_HARD     // Decline and revert POP creation
}

/// @title ITruthKeeper
/// @notice Interface for TruthKeeper contracts that validate and approve POPs
interface ITruthKeeper {
    /// @notice Pre-check if TK would accept a POP with these parameters
    /// @dev View function for gas-efficient dry-runs and UI pre-validation
    /// @param resolver The resolver contract address
    /// @param templateId The template ID within the resolver
    /// @param creator The address creating the POP
    /// @param payload The resolver-specific payload (raw bytes)
    /// @param disputeWindow Time window for disputing resolution
    /// @param truthKeeperWindow Time window for TK to decide disputes
    /// @param escalationWindow Time window to challenge TK decision
    /// @param postResolutionWindow Time window for post-resolution disputes
    /// @return response The approval decision TK would make
    function canAcceptPop(
        address resolver,
        uint32 templateId,
        address creator,
        bytes calldata payload,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 escalationWindow,
        uint32 postResolutionWindow
    ) external view returns (TKApprovalResponse response);

    /// @notice Called when a POP is created with this TK assigned
    /// @dev Can update internal state (track POPs, counters, etc.)
    /// @param popId The newly created POP ID
    /// @param resolver The resolver contract address
    /// @param templateId The template ID within the resolver
    /// @param creator The address creating the POP
    /// @param payload The resolver-specific payload (raw bytes)
    /// @param disputeWindow Time window for disputing resolution
    /// @param truthKeeperWindow Time window for TK to decide disputes
    /// @param escalationWindow Time window to challenge TK decision
    /// @param postResolutionWindow Time window for post-resolution disputes
    /// @return response The approval decision
    function onPopAssigned(
        uint256 popId,
        address resolver,
        uint32 templateId,
        address creator,
        bytes calldata payload,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 escalationWindow,
        uint32 postResolutionWindow
    ) external returns (TKApprovalResponse response);
}
```

---

## POPRegistry Changes

### Remove

- `mapping(address => EnumerableSet.AddressSet) private _tkGuaranteedResolvers`
- `addGuaranteedResolver(address resolver)`
- `removeGuaranteedResolver(address resolver)`
- `getTruthKeeperGuaranteedResolvers(address tk)`
- `isTruthKeeperGuaranteedResolver(address tk, address resolver)`
- Events: `TruthKeeperGuaranteeAdded`, `TruthKeeperGuaranteeRemoved`

### Add

- New error: `TruthKeeperNotContract(address tk)`
- New error: `TruthKeeperRejected(address tk, uint256 popId)`
- New event: `TruthKeeperApproved(uint256 indexed popId, address indexed tk)`
- New event: `TruthKeeperSoftRejected(uint256 indexed popId, address indexed tk)`

### Modified createPOP Flow

```solidity
function createPOP(..., address truthKeeper) external returns (uint256 popId) {
    // ... existing validation ...

    // NEW: Verify TK is a contract
    if (truthKeeper.code.length == 0) {
        revert TruthKeeperNotContract(truthKeeper);
    }

    // Assign popId
    popId = ++_popCounter;
    POP storage pop = _pops[popId];

    // ... set pop fields ...

    // NEW: Call TK for approval
    TKApprovalResponse tkResponse = ITruthKeeper(truthKeeper).onPopAssigned(
        popId,
        resolver,
        templateId,
        msg.sender,
        payload,
        disputeWindow,
        truthKeeperWindow,
        escalationWindow,
        postResolutionWindow
    );

    // NEW: Handle response
    bool tkApproved;
    if (tkResponse == TKApprovalResponse.REJECT_HARD) {
        revert TruthKeeperRejected(truthKeeper, popId);
    } else if (tkResponse == TKApprovalResponse.APPROVE) {
        tkApproved = true;
        emit TruthKeeperApproved(popId, truthKeeper);
    } else {
        // REJECT_SOFT
        tkApproved = false;
        emit TruthKeeperSoftRejected(popId, truthKeeper);
    }

    // NEW: Calculate tier with approval status
    pop.tierAtCreation = _calculateAccountabilityTier(resolver, truthKeeper, tkApproved);

    // Call resolver (existing)
    pop.state = IPopResolver(resolver).onPopCreated(popId, templateId, payload);

    emit POPCreated(...);
}
```

### New Tier Calculation

```solidity
function _calculateAccountabilityTier(
    address resolver,
    address tk,
    bool tkApproved
) internal view returns (AccountabilityTier) {
    // No approval = PERMISSIONLESS
    if (!tkApproved) {
        return AccountabilityTier.PERMISSIONLESS;
    }

    // SYSTEM: SYSTEM resolver + whitelisted TK + approved
    if (_resolverConfigs[resolver].trust == ResolverTrust.SYSTEM
        && _whitelistedTruthKeepers.contains(tk)) {
        return AccountabilityTier.SYSTEM;
    }

    // TK approved but not SYSTEM conditions
    return AccountabilityTier.TK_GUARANTEED;
}
```

---

## Example: ConfigurableTruthKeeper

A reference implementation showing how TK contracts can filter POPs.

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper, TKApprovalResponse} from "./ITruthKeeper.sol";

/// @title ConfigurableTruthKeeper
/// @notice Example TK that filters POPs based on configurable criteria
contract ConfigurableTruthKeeper is ITruthKeeper {
    address public owner;
    address public registry;

    // Filters
    uint32 public minDisputeWindow;
    uint32 public minTruthKeeperWindow;
    mapping(address => bool) public allowedResolvers;    // empty = allow all
    mapping(address => bool) public blockedResolvers;
    mapping(address => bool) public allowedCreators;     // empty = allow all
    mapping(address => bool) public blockedCreators;
    mapping(address => mapping(uint32 => bool)) public blockedTemplates; // resolver => templateId

    bool public useResolverAllowlist;
    bool public useCreatorAllowlist;

    error OnlyRegistry();
    error OnlyOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }

    constructor(address _registry, address _owner) {
        registry = _registry;
        owner = _owner;
        minDisputeWindow = 1 hours;
        minTruthKeeperWindow = 4 hours;
    }

    // ============ ITruthKeeper Implementation ============

    function canAcceptPop(
        address resolver,
        uint32 templateId,
        address creator,
        bytes calldata /* payload */,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external view returns (TKApprovalResponse) {
        return _evaluate(resolver, templateId, creator, disputeWindow, truthKeeperWindow);
    }

    function onPopAssigned(
        uint256 /* popId */,
        address resolver,
        uint32 templateId,
        address creator,
        bytes calldata /* payload */,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external onlyRegistry returns (TKApprovalResponse) {
        // Could track popId internally here if needed
        return _evaluate(resolver, templateId, creator, disputeWindow, truthKeeperWindow);
    }

    function _evaluate(
        address resolver,
        uint32 templateId,
        address creator,
        uint32 disputeWindow,
        uint32 truthKeeperWindow
    ) internal view returns (TKApprovalResponse) {
        // Hard reject: blocked resolver or creator
        if (blockedResolvers[resolver]) return TKApprovalResponse.REJECT_HARD;
        if (blockedCreators[creator]) return TKApprovalResponse.REJECT_HARD;
        if (blockedTemplates[resolver][templateId]) return TKApprovalResponse.REJECT_HARD;

        // Hard reject: time windows too short
        if (disputeWindow < minDisputeWindow) return TKApprovalResponse.REJECT_HARD;
        if (truthKeeperWindow < minTruthKeeperWindow) return TKApprovalResponse.REJECT_HARD;

        // Soft reject: not on allowlist (if using allowlists)
        if (useResolverAllowlist && !allowedResolvers[resolver]) {
            return TKApprovalResponse.REJECT_SOFT;
        }
        if (useCreatorAllowlist && !allowedCreators[creator]) {
            return TKApprovalResponse.REJECT_SOFT;
        }

        return TKApprovalResponse.APPROVE;
    }

    // ============ Owner Configuration ============

    function setMinWindows(uint32 _dispute, uint32 _tk) external onlyOwner {
        minDisputeWindow = _dispute;
        minTruthKeeperWindow = _tk;
    }

    function setResolverAllowlist(bool enabled) external onlyOwner {
        useResolverAllowlist = enabled;
    }

    function setCreatorAllowlist(bool enabled) external onlyOwner {
        useCreatorAllowlist = enabled;
    }

    function allowResolver(address resolver, bool allowed) external onlyOwner {
        allowedResolvers[resolver] = allowed;
    }

    function blockResolver(address resolver, bool blocked) external onlyOwner {
        blockedResolvers[resolver] = blocked;
    }

    function allowCreator(address creator, bool allowed) external onlyOwner {
        allowedCreators[creator] = allowed;
    }

    function blockCreator(address creator, bool blocked) external onlyOwner {
        blockedCreators[creator] = blocked;
    }

    function blockTemplate(address resolver, uint32 templateId, bool blocked) external onlyOwner {
        blockedTemplates[resolver][templateId] = blocked;
    }
}
```

---

## Security Considerations

1. **Reentrancy** - TK callback happens during createPOP; ensure proper ordering and use nonReentrant
2. **Gas griefing** - Malicious TK could consume excessive gas; consider gas limit on callback
3. **TK contract upgrades** - If TK is upgradeable proxy, approval logic can change
4. **Registry trust** - TK must verify caller is the registry in onPopAssigned

---

## Files to Create/Modify

1. `contracts/Popregistry/POPTypes.sol` - Add TKApprovalResponse enum
2. `contracts/Popregistry/ITruthKeeper.sol` - New interface file
3. `contracts/Popregistry/POPRegistry.sol` - Update createPOP, remove guarantee mappings
4. `contracts/Popregistry/IPOPRegistry.sol` - Remove guarantee functions from interface
5. `contracts/examples/ConfigurableTruthKeeper.sol` - Reference implementation
6. `contracts/test/POPRegistry.t.sol` - Update tests for new flow

---

## Summary

| Aspect | Before | After |
|--------|--------|-------|
| TK type | EOA or Contract | Contract only |
| Approval | Implicit (resolver guarantee) | Explicit (per-POP callback) |
| Tier upgrade | TK guarantees resolver | TK approves specific POP |
| Flexibility | Resolver-level only | Per-POP with full context |
| Rejection | Not possible | Soft (PERMISSIONLESS) or Hard (revert) |
