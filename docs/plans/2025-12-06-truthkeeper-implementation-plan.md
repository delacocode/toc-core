# TruthKeeper Two-Round Dispute System - Implementation Plan

**Date:** 2025-12-06
**Design Document:** `docs/plans/2025-12-06-truthkeeper-dispute-system-design.md`

---

## Task 1: Update TOCTypes.sol - Enums

**File:** `contracts/TOCregistry/TOCTypes.sol`

### 1.1 Add AccountabilityTier enum (after ResolverType)

```solidity
/// @notice Accountability tier for a TOC (snapshot at creation)
enum AccountabilityTier {
    NONE,           // Default/uninitialized
    PERMISSIONLESS, // No guarantees - creator's risk
    TK_GUARANTEED,  // TruthKeeper guarantees response
    SYSTEM          // System takes full accountability
}
```

### 1.2 Update TOCState enum

Replace:
```solidity
enum TOCState {
    NONE,           // Default/uninitialized
    PENDING,        // Created, awaiting resolver approval
    REJECTED,       // Resolver rejected during creation
    ACTIVE,         // Approved, markets can trade
    RESOLVING,      // Outcome proposed, dispute window open
    DISPUTED,       // Dispute raised, admin reviewing
    RESOLVED,       // Final outcome set, immutable
    CANCELLED       // Admin cancelled, markets should refund
}
```

With:
```solidity
enum TOCState {
    NONE,               // Default/uninitialized
    PENDING,            // Created, awaiting resolver approval
    REJECTED,           // Resolver rejected during creation
    ACTIVE,             // Approved, markets can trade
    RESOLVING,          // Outcome proposed, dispute window open
    DISPUTED_ROUND_1,   // Dispute raised, TruthKeeper reviewing
    DISPUTED_ROUND_2,   // TK decision challenged, Admin/Community reviewing
    RESOLVED,           // Final outcome set, immutable
    CANCELLED           // Admin cancelled, markets should refund
}
```

### 1.3 Update DisputeResolution enum

Replace:
```solidity
enum DisputeResolution {
    UPHOLD_DISPUTE,  // Disputer was right, override outcome
    REJECT_DISPUTE,  // Original outcome stands
    CANCEL_TOC       // Entire TOC is invalid, refund all
}
```

With:
```solidity
enum DisputeResolution {
    UPHOLD_DISPUTE,  // Disputer was right, override outcome
    REJECT_DISPUTE,  // Original outcome stands
    CANCEL_TOC,      // Entire TOC is invalid, refund all
    TOO_EARLY        // Event hasn't occurred, return to ACTIVE
}
```

---

## Task 2: Update TOCTypes.sol - Structs

**File:** `contracts/TOCregistry/TOCTypes.sol`

### 2.1 Update TOC struct

Replace:
```solidity
struct TOC {
    address resolver;           // Which resolver manages this TOC
    TOCState state;             // Current state
    AnswerType answerType;      // Type of answer this TOC will return
    uint256 resolutionTime;     // Timestamp when resolved
    uint256 disputeWindow;      // User-specified pre-resolution dispute duration
    uint256 postResolutionWindow; // User-specified post-resolution dispute duration
    uint256 disputeDeadline;    // Computed: end of pre-resolution dispute window
    uint256 postDisputeDeadline; // Computed: end of post-resolution dispute window
}
```

With:
```solidity
struct TOC {
    address resolver;               // Which resolver manages this TOC
    TOCState state;                 // Current state
    AnswerType answerType;          // Type of answer this TOC will return
    uint256 resolutionTime;         // Timestamp when resolved

    // Time windows (user-specified per-TOC)
    uint256 disputeWindow;          // Time to dispute initial proposal (Round 1)
    uint256 truthKeeperWindow;      // Time for TruthKeeper to decide
    uint256 escalationWindow;       // Time to challenge TruthKeeper decision
    uint256 postResolutionWindow;   // Time to dispute after RESOLVED

    // Computed deadlines
    uint256 disputeDeadline;        // End of pre-resolution dispute window
    uint256 truthKeeperDeadline;    // End of TruthKeeper decision window
    uint256 escalationDeadline;     // End of escalation window
    uint256 postDisputeDeadline;    // End of post-resolution dispute window

    // TruthKeeper
    address truthKeeper;            // Assigned TruthKeeper for this TOC
    AccountabilityTier tierAtCreation; // Immutable snapshot of tier
}
```

### 2.2 Update DisputeInfo struct

Replace:
```solidity
struct DisputeInfo {
    DisputePhase phase;         // When dispute was filed (pre or post resolution)
    address disputer;           // Who disputed
    address bondToken;          // Token used for dispute bond
    uint256 bondAmount;         // Amount of bond held
    string reason;              // Dispute reason
    uint256 filedAt;            // Timestamp when dispute was filed
    uint256 resolvedAt;         // Timestamp when dispute was resolved (0 if pending)
    bool resultCorrected;       // Whether the result was corrected (dispute upheld)
    // Disputer's proposed correction (optional)
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;
}
```

With:
```solidity
struct DisputeInfo {
    DisputePhase phase;             // When dispute was filed (pre or post resolution)
    address disputer;               // Who disputed
    address bondToken;              // Token used for dispute bond
    uint256 bondAmount;             // Amount of bond held
    string reason;                  // Dispute reason
    string evidenceURI;             // IPFS/Arweave link for detailed evidence
    uint256 filedAt;                // Timestamp when dispute was filed
    uint256 resolvedAt;             // Timestamp when dispute was resolved (0 if pending)
    bool resultCorrected;           // Whether the result was corrected (dispute upheld)

    // Disputer's proposed correction (optional)
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;

    // TruthKeeper decision (Round 1)
    DisputeResolution tkDecision;   // TK's decision (NONE if not yet decided)
    uint256 tkDecidedAt;            // Timestamp when TK decided (0 if pending)
}
```

### 2.3 Add EscalationInfo struct (after DisputeInfo)

```solidity
/// @notice Information about a Round 2 escalation (challenging TruthKeeper decision)
struct EscalationInfo {
    address challenger;             // Who challenged the TK decision
    address bondToken;              // Token used for escalation bond
    uint256 bondAmount;             // Amount of escalation bond (higher than Round 1)
    string reason;                  // Reason for challenging TK
    string evidenceURI;             // IPFS/Arweave link for detailed evidence
    uint256 filedAt;                // Timestamp when escalation was filed
    uint256 resolvedAt;             // Timestamp when admin resolved (0 if pending)

    // Challenger's proposed correction (optional)
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;
}
```

### 2.4 Update TOCInfo struct

Replace:
```solidity
struct TOCInfo {
    // TOC fields
    address resolver;
    TOCState state;
    AnswerType answerType;
    uint256 resolutionTime;
    uint256 disputeWindow;
    uint256 postResolutionWindow;
    uint256 disputeDeadline;
    uint256 postDisputeDeadline;
    // Result (only valid when state == RESOLVED)
    bool isResolved;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;
    // Corrected result (if post-resolution dispute was upheld)
    bool hasCorrectedResult;
    bool correctedBooleanResult;
    int256 correctedNumericResult;
    bytes correctedGenericResult;
    // Resolver context
    ResolverType resolverType;
    uint256 resolverId;
    bool resolverIsActive;
}
```

With:
```solidity
struct TOCInfo {
    // TOC fields
    address resolver;
    TOCState state;
    AnswerType answerType;
    uint256 resolutionTime;

    // Time windows
    uint256 disputeWindow;
    uint256 truthKeeperWindow;
    uint256 escalationWindow;
    uint256 postResolutionWindow;

    // Deadlines
    uint256 disputeDeadline;
    uint256 truthKeeperDeadline;
    uint256 escalationDeadline;
    uint256 postDisputeDeadline;

    // TruthKeeper
    address truthKeeper;
    AccountabilityTier tierAtCreation;

    // Result (only valid when state == RESOLVED)
    bool isResolved;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;

    // Corrected result (if dispute was upheld)
    bool hasCorrectedResult;
    bool correctedBooleanResult;
    int256 correctedNumericResult;
    bytes correctedGenericResult;

    // Resolver context
    ResolverType resolverType;
    uint256 resolverId;
    bool resolverIsActive;
}
```

---

## Task 3: Update ITOCRegistry.sol - Events

**File:** `contracts/TOCregistry/ITOCRegistry.sol`

### 3.1 Add TruthKeeper registry events (after existing Resolver events)

```solidity
// TruthKeeper registry
event TruthKeeperWhitelisted(address indexed tk);
event TruthKeeperRemovedFromWhitelist(address indexed tk);
event ResolverAddedToWhitelist(address indexed resolver);
event ResolverRemovedFromWhitelist(address indexed resolver);
event TruthKeeperGuaranteeAdded(address indexed tk, address indexed resolver);
event TruthKeeperGuaranteeRemoved(address indexed tk, address indexed resolver);
```

### 3.2 Add TruthKeeper dispute events (after existing Dispute events)

```solidity
// TruthKeeper dispute flow
event TruthKeeperDisputeResolved(
    uint256 indexed tocId,
    address indexed tk,
    DisputeResolution resolution
);
event TruthKeeperDecisionChallenged(
    uint256 indexed tocId,
    address indexed challenger,
    string reason
);
event TruthKeeperTimedOut(
    uint256 indexed tocId,
    address indexed tk
);
event EscalationResolved(
    uint256 indexed tocId,
    DisputeResolution resolution,
    address indexed admin
);
```

### 3.3 Update TOCCreated event

Replace:
```solidity
event TOCCreated(
    uint256 indexed tocId,
    ResolverType indexed resolverType,
    uint256 indexed resolverId,
    address resolver,
    uint32 templateId,
    AnswerType answerType,
    TOCState initialState
);
```

With:
```solidity
event TOCCreated(
    uint256 indexed tocId,
    ResolverType indexed resolverType,
    uint256 indexed resolverId,
    address resolver,
    uint32 templateId,
    AnswerType answerType,
    TOCState initialState,
    address truthKeeper,
    AccountabilityTier tier
);
```

---

## Task 4: Update ITOCRegistry.sol - Admin Functions

**File:** `contracts/TOCregistry/ITOCRegistry.sol`

### 4.1 Add TruthKeeper whitelist admin functions

```solidity
/// @notice Add a TruthKeeper to the system whitelist
/// @param tk Address of the TruthKeeper
function addWhitelistedTruthKeeper(address tk) external;

/// @notice Remove a TruthKeeper from the system whitelist
/// @param tk Address of the TruthKeeper
function removeWhitelistedTruthKeeper(address tk) external;

/// @notice Add a resolver to the system whitelist (for SYSTEM tier)
/// @param resolver Address of the resolver
function addWhitelistedResolver(address resolver) external;

/// @notice Remove a resolver from the system whitelist
/// @param resolver Address of the resolver
function removeWhitelistedResolver(address resolver) external;

/// @notice Add an acceptable bond token/amount for escalations (Round 2)
/// @param token Token address (address(0) for native)
/// @param minAmount Minimum amount required (should be higher than dispute bonds)
function addAcceptableEscalationBond(address token, uint256 minAmount) external;
```

---

## Task 5: Update ITOCRegistry.sol - TruthKeeper Functions

**File:** `contracts/TOCregistry/ITOCRegistry.sol`

### 5.1 Add TruthKeeper self-management functions

```solidity
// ============ TruthKeeper Functions ============

/// @notice TruthKeeper adds a resolver to their guaranteed list
/// @param resolver Address of resolver they guarantee to handle
function addGuaranteedResolver(address resolver) external;

/// @notice TruthKeeper removes a resolver from their guaranteed list
/// @param resolver Address of resolver to remove
function removeGuaranteedResolver(address resolver) external;

/// @notice TruthKeeper resolves a Round 1 dispute
/// @param tocId The disputed TOC
/// @param resolution How to resolve (UPHOLD_DISPUTE, REJECT_DISPUTE, CANCEL_TOC, TOO_EARLY)
/// @param correctedBooleanResult Corrected boolean result (if upholding)
/// @param correctedNumericResult Corrected numeric result (if upholding)
/// @param correctedGenericResult Corrected generic result (if upholding)
function resolveTruthKeeperDispute(
    uint256 tocId,
    DisputeResolution resolution,
    bool correctedBooleanResult,
    int256 correctedNumericResult,
    bytes calldata correctedGenericResult
) external;
```

---

## Task 6: Update ITOCRegistry.sol - TOC Creation

**File:** `contracts/TOCregistry/ITOCRegistry.sol`

### 6.1 Update createTOCWithSystemResolver

Replace:
```solidity
function createTOCWithSystemResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) external returns (uint256 tocId);
```

With:
```solidity
function createTOCWithSystemResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper
) external returns (uint256 tocId);
```

### 6.2 Update createTOCWithPublicResolver

Replace:
```solidity
function createTOCWithPublicResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) external returns (uint256 tocId);
```

With:
```solidity
function createTOCWithPublicResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper
) external returns (uint256 tocId);
```

---

## Task 7: Update ITOCRegistry.sol - Dispute Functions

**File:** `contracts/TOCregistry/ITOCRegistry.sol`

### 7.1 Update dispute function

Replace:
```solidity
function dispute(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable;
```

With:
```solidity
function dispute(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    string calldata evidenceURI,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable;
```

### 7.2 Add escalation functions

```solidity
/// @notice Challenge a TruthKeeper's decision (escalate to Round 2)
/// @param tocId The TOC with TK decision to challenge
/// @param bondToken Token for escalation bond (must be acceptable)
/// @param bondAmount Amount of escalation bond (higher than dispute bond)
/// @param reason Reason for challenging TK decision
/// @param evidenceURI IPFS/Arweave link for detailed evidence
/// @param proposedBooleanResult Challenger's proposed boolean result
/// @param proposedNumericResult Challenger's proposed numeric result
/// @param proposedGenericResult Challenger's proposed generic result
function challengeTruthKeeperDecision(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    string calldata evidenceURI,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable;

/// @notice Finalize a TOC after TruthKeeper decision (if no challenge)
/// @param tocId The TOC to finalize
function finalizeAfterTruthKeeper(uint256 tocId) external;

/// @notice Escalate to Round 2 if TruthKeeper times out
/// @param tocId The TOC where TK timed out
function escalateTruthKeeperTimeout(uint256 tocId) external;

/// @notice Admin resolves a Round 2 escalation
/// @param tocId The escalated TOC
/// @param resolution How to resolve the escalation
/// @param correctedBooleanResult Admin's corrected boolean result
/// @param correctedNumericResult Admin's corrected numeric result
/// @param correctedGenericResult Admin's corrected generic result
function resolveEscalation(
    uint256 tocId,
    DisputeResolution resolution,
    bool correctedBooleanResult,
    int256 correctedNumericResult,
    bytes calldata correctedGenericResult
) external;
```

---

## Task 8: Update ITOCRegistry.sol - View Functions

**File:** `contracts/TOCregistry/ITOCRegistry.sol`

### 8.1 Add TruthKeeper view functions

```solidity
// ============ TruthKeeper View Functions ============

/// @notice Check if an address is a whitelisted TruthKeeper
/// @param tk Address to check
/// @return True if whitelisted
function isWhitelistedTruthKeeper(address tk) external view returns (bool);

/// @notice Check if a resolver is whitelisted for SYSTEM tier
/// @param resolver Address to check
/// @return True if whitelisted
function isWhitelistedResolver(address resolver) external view returns (bool);

/// @notice Get list of resolvers a TruthKeeper guarantees
/// @param tk TruthKeeper address
/// @return Array of resolver addresses
function getTruthKeeperGuaranteedResolvers(address tk) external view returns (address[] memory);

/// @notice Check if TruthKeeper guarantees a specific resolver
/// @param tk TruthKeeper address
/// @param resolver Resolver address
/// @return True if TK guarantees this resolver
function isTruthKeeperGuaranteedResolver(address tk, address resolver) external view returns (bool);

/// @notice Get escalation info for a TOC
/// @param tocId The TOC identifier
/// @return info The escalation information
function getEscalationInfo(uint256 tocId) external view returns (EscalationInfo memory info);

/// @notice Calculate accountability tier for a resolver + TK combination
/// @param resolver Resolver address
/// @param tk TruthKeeper address
/// @return tier The accountability tier
function calculateAccountabilityTier(address resolver, address tk) external view returns (AccountabilityTier tier);

/// @notice Check if a bond is acceptable for escalation
/// @param token Token address
/// @param amount Amount
/// @return True if acceptable
function isAcceptableEscalationBond(address token, uint256 amount) external view returns (bool);
```

---

## Task 9: Update TOCRegistry.sol - Storage

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 9.1 Add new storage variables (after existing storage)

```solidity
// ============ TruthKeeper Registry ============

// System-level whitelists (admin controlled)
EnumerableSet.AddressSet private _whitelistedTruthKeepers;
EnumerableSet.AddressSet private _whitelistedResolvers;

// TruthKeeper self-declared guarantees: tk => set of resolvers
mapping(address => EnumerableSet.AddressSet) private _tkGuaranteedResolvers;

// Escalation bonds (Round 2)
BondRequirement[] private _acceptableEscalationBonds;

// Escalation info storage
mapping(uint256 => EscalationInfo) private _escalations;
```

### 9.2 Add new errors

```solidity
error NotTruthKeeper(address caller, address expected);
error TruthKeeperNotWhitelisted(address tk);
error TruthKeeperAlreadyWhitelisted(address tk);
error ResolverNotWhitelistedForSystem(address resolver);
error TruthKeeperWindowNotPassed(uint256 deadline, uint256 current);
error EscalationWindowNotPassed(uint256 deadline, uint256 current);
error EscalationWindowPassed(uint256 deadline, uint256 current);
error NotInDisputedRound1State(TOCState currentState);
error NotInDisputedRound2State(TOCState currentState);
error TruthKeeperAlreadyDecided(uint256 tocId);
error AlreadyEscalated(uint256 tocId);
error InvalidTruthKeeper(address tk);
```

---

## Task 10: Update TOCRegistry.sol - Admin Functions

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 10.1 Add TruthKeeper whitelist management

```solidity
/// @inheritdoc ITOCRegistry
function addWhitelistedTruthKeeper(address tk) external onlyOwner {
    if (tk == address(0)) revert InvalidTruthKeeper(tk);
    if (_whitelistedTruthKeepers.contains(tk)) revert TruthKeeperAlreadyWhitelisted(tk);
    _whitelistedTruthKeepers.add(tk);
    emit TruthKeeperWhitelisted(tk);
}

/// @inheritdoc ITOCRegistry
function removeWhitelistedTruthKeeper(address tk) external onlyOwner {
    if (!_whitelistedTruthKeepers.contains(tk)) revert TruthKeeperNotWhitelisted(tk);
    _whitelistedTruthKeepers.remove(tk);
    emit TruthKeeperRemovedFromWhitelist(tk);
}

/// @inheritdoc ITOCRegistry
function addWhitelistedResolver(address resolver) external onlyOwner {
    if (resolver == address(0)) revert ResolverNotRegistered(resolver);
    _whitelistedResolvers.add(resolver);
    emit ResolverAddedToWhitelist(resolver);
}

/// @inheritdoc ITOCRegistry
function removeWhitelistedResolver(address resolver) external onlyOwner {
    _whitelistedResolvers.remove(resolver);
    emit ResolverRemovedFromWhitelist(resolver);
}

/// @inheritdoc ITOCRegistry
function addAcceptableEscalationBond(address token, uint256 minAmount) external onlyOwner {
    _acceptableEscalationBonds.push(BondRequirement({
        token: token,
        minAmount: minAmount
    }));
}
```

---

## Task 11: Update TOCRegistry.sol - TruthKeeper Functions

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 11.1 Add modifier for TruthKeeper

```solidity
modifier onlyTruthKeeper(uint256 tocId) {
    TOC storage toc = _tocs[tocId];
    if (msg.sender != toc.truthKeeper) {
        revert NotTruthKeeper(msg.sender, toc.truthKeeper);
    }
    _;
}
```

### 11.2 Add TruthKeeper guarantee management

```solidity
/// @inheritdoc ITOCRegistry
function addGuaranteedResolver(address resolver) external {
    _tkGuaranteedResolvers[msg.sender].add(resolver);
    emit TruthKeeperGuaranteeAdded(msg.sender, resolver);
}

/// @inheritdoc ITOCRegistry
function removeGuaranteedResolver(address resolver) external {
    _tkGuaranteedResolvers[msg.sender].remove(resolver);
    emit TruthKeeperGuaranteeRemoved(msg.sender, resolver);
}
```

### 11.3 Add TruthKeeper dispute resolution

```solidity
/// @inheritdoc ITOCRegistry
function resolveTruthKeeperDispute(
    uint256 tocId,
    DisputeResolution resolution,
    bool correctedBooleanResult,
    int256 correctedNumericResult,
    bytes calldata correctedGenericResult
) external nonReentrant validTocId(tocId) onlyTruthKeeper(tocId) {
    TOC storage toc = _tocs[tocId];

    if (toc.state != TOCState.DISPUTED_ROUND_1) {
        revert NotInDisputedRound1State(toc.state);
    }

    DisputeInfo storage disputeInfo = _disputes[tocId];

    if (disputeInfo.tkDecidedAt != 0) {
        revert TruthKeeperAlreadyDecided(tocId);
    }

    // Record TK decision
    disputeInfo.tkDecision = resolution;
    disputeInfo.tkDecidedAt = block.timestamp;

    // Set escalation deadline
    toc.escalationDeadline = block.timestamp + toc.escalationWindow;

    // Handle TOO_EARLY specially - immediately return to ACTIVE
    if (resolution == DisputeResolution.TOO_EARLY) {
        _handleTooEarlyResolution(tocId, toc, disputeInfo);
    }
    // Other resolutions wait for escalation window

    emit TruthKeeperDisputeResolved(tocId, msg.sender, resolution);
}
```

---

## Task 12: Update TOCRegistry.sol - TOC Creation

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 12.1 Update _createTOC function

Update the function signature and implementation to include TruthKeeper and new windows. Key changes:

```solidity
function _createTOC(
    ResolverType resolverType,
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper
) internal returns (uint256 tocId) {
    // ... existing resolver validation ...

    // Calculate accountability tier
    AccountabilityTier tier = _calculateAccountabilityTier(resolver, truthKeeper);

    tocId = _nextTocId++;

    TOCState initialState = ITocResolver(resolver).onTocCreated(tocId, templateId, payload);

    _tocs[tocId] = TOC({
        resolver: resolver,
        state: initialState,
        answerType: answerType,
        resolutionTime: 0,
        disputeWindow: disputeWindow,
        truthKeeperWindow: truthKeeperWindow,
        escalationWindow: escalationWindow,
        postResolutionWindow: postResolutionWindow,
        disputeDeadline: 0,
        truthKeeperDeadline: 0,
        escalationDeadline: 0,
        postDisputeDeadline: 0,
        truthKeeper: truthKeeper,
        tierAtCreation: tier
    });

    emit TOCCreated(tocId, resolverType, resolverId, resolver, templateId, answerType, initialState, truthKeeper, tier);
}
```

---

## Task 13: Update TOCRegistry.sol - Dispute Flow

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 13.1 Update dispute function

Update to:
- Accept `evidenceURI` parameter
- Change state to `DISPUTED_ROUND_1` instead of `DISPUTED`
- Set `truthKeeperDeadline`

### 13.2 Add challengeTruthKeeperDecision

```solidity
/// @inheritdoc ITOCRegistry
function challengeTruthKeeperDecision(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    string calldata evidenceURI,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable nonReentrant validTocId(tocId) {
    TOC storage toc = _tocs[tocId];
    DisputeInfo storage disputeInfo = _disputes[tocId];

    // Must be in DISPUTED_ROUND_1 with TK decision made
    if (toc.state != TOCState.DISPUTED_ROUND_1) {
        revert NotInDisputedRound1State(toc.state);
    }
    if (disputeInfo.tkDecidedAt == 0) {
        revert TruthKeeperAlreadyDecided(tocId); // Not decided yet
    }

    // Check escalation window
    if (block.timestamp >= toc.escalationDeadline) {
        revert EscalationWindowPassed(toc.escalationDeadline, block.timestamp);
    }

    // Check not already escalated
    if (_escalations[tocId].challenger != address(0)) {
        revert AlreadyEscalated(tocId);
    }

    // Validate escalation bond (higher than dispute bond)
    if (!_isAcceptableEscalationBond(bondToken, bondAmount)) {
        revert InvalidBond(bondToken, bondAmount);
    }
    _transferBondIn(bondToken, bondAmount);

    // Store escalation info
    _escalations[tocId] = EscalationInfo({
        challenger: msg.sender,
        bondToken: bondToken,
        bondAmount: bondAmount,
        reason: reason,
        evidenceURI: evidenceURI,
        filedAt: block.timestamp,
        resolvedAt: 0,
        proposedBooleanResult: proposedBooleanResult,
        proposedNumericResult: proposedNumericResult,
        proposedGenericResult: proposedGenericResult
    });

    // Move to Round 2
    toc.state = TOCState.DISPUTED_ROUND_2;

    emit TruthKeeperDecisionChallenged(tocId, msg.sender, reason);
}
```

### 13.3 Add finalizeAfterTruthKeeper

```solidity
/// @inheritdoc ITOCRegistry
function finalizeAfterTruthKeeper(uint256 tocId) external nonReentrant validTocId(tocId) {
    TOC storage toc = _tocs[tocId];
    DisputeInfo storage disputeInfo = _disputes[tocId];

    if (toc.state != TOCState.DISPUTED_ROUND_1) {
        revert NotInDisputedRound1State(toc.state);
    }

    // TK must have decided
    if (disputeInfo.tkDecidedAt == 0) {
        revert TruthKeeperAlreadyDecided(tocId);
    }

    // Escalation window must have passed
    if (block.timestamp < toc.escalationDeadline) {
        revert EscalationWindowNotPassed(toc.escalationDeadline, block.timestamp);
    }

    // Must not have been escalated
    if (_escalations[tocId].challenger != address(0)) {
        revert AlreadyEscalated(tocId);
    }

    // Apply TK's decision
    _applyDisputeResolution(tocId, disputeInfo.tkDecision, ...);
}
```

### 13.4 Add escalateTruthKeeperTimeout

```solidity
/// @inheritdoc ITOCRegistry
function escalateTruthKeeperTimeout(uint256 tocId) external nonReentrant validTocId(tocId) {
    TOC storage toc = _tocs[tocId];
    DisputeInfo storage disputeInfo = _disputes[tocId];

    if (toc.state != TOCState.DISPUTED_ROUND_1) {
        revert NotInDisputedRound1State(toc.state);
    }

    // TK must NOT have decided
    if (disputeInfo.tkDecidedAt != 0) {
        revert TruthKeeperAlreadyDecided(tocId);
    }

    // TK window must have passed
    if (block.timestamp < toc.truthKeeperDeadline) {
        revert TruthKeeperWindowNotPassed(toc.truthKeeperDeadline, block.timestamp);
    }

    // Auto-escalate to Round 2
    toc.state = TOCState.DISPUTED_ROUND_2;

    emit TruthKeeperTimedOut(tocId, toc.truthKeeper);
}
```

---

## Task 14: Update TOCRegistry.sol - Bond Economics

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 14.1 Update bond distribution to 50/50 split

Create helper function:

```solidity
/// @notice Distribute slashed bond: 50% to winner, 50% to contract
function _slashBondWithReward(
    address loser,
    address winner,
    address token,
    uint256 amount
) internal {
    uint256 winnerShare = amount / 2;
    uint256 contractShare = amount - winnerShare; // Handles odd amounts

    // Transfer winner's share
    _transferBondOut(winner, token, winnerShare);

    // Contract keeps the rest (stays in contract)
    emit BondSlashed(loser, token, contractShare);
}
```

Update all dispute resolution logic to use this pattern.

---

## Task 15: Update TOCRegistry.sol - View Functions

**File:** `contracts/TOCregistry/TOCRegistry.sol`

### 15.1 Add new view functions

```solidity
/// @inheritdoc ITOCRegistry
function isWhitelistedTruthKeeper(address tk) external view returns (bool) {
    return _whitelistedTruthKeepers.contains(tk);
}

/// @inheritdoc ITOCRegistry
function isWhitelistedResolver(address resolver) external view returns (bool) {
    return _whitelistedResolvers.contains(resolver);
}

/// @inheritdoc ITOCRegistry
function getTruthKeeperGuaranteedResolvers(address tk) external view returns (address[] memory) {
    return _tkGuaranteedResolvers[tk].values();
}

/// @inheritdoc ITOCRegistry
function isTruthKeeperGuaranteedResolver(address tk, address resolver) external view returns (bool) {
    return _tkGuaranteedResolvers[tk].contains(resolver);
}

/// @inheritdoc ITOCRegistry
function getEscalationInfo(uint256 tocId) external view returns (EscalationInfo memory) {
    return _escalations[tocId];
}

/// @inheritdoc ITOCRegistry
function calculateAccountabilityTier(address resolver, address tk) external view returns (AccountabilityTier) {
    return _calculateAccountabilityTier(resolver, tk);
}

function _calculateAccountabilityTier(address resolver, address tk) internal view returns (AccountabilityTier) {
    if (_whitelistedResolvers.contains(resolver) && _whitelistedTruthKeepers.contains(tk)) {
        return AccountabilityTier.SYSTEM;
    }
    if (_tkGuaranteedResolvers[tk].contains(resolver)) {
        return AccountabilityTier.TK_GUARANTEED;
    }
    return AccountabilityTier.PERMISSIONLESS;
}

/// @inheritdoc ITOCRegistry
function isAcceptableEscalationBond(address token, uint256 amount) external view returns (bool) {
    return _isAcceptableEscalationBond(token, amount);
}

function _isAcceptableEscalationBond(address token, uint256 amount) internal view returns (bool) {
    for (uint256 i = 0; i < _acceptableEscalationBonds.length; i++) {
        if (_acceptableEscalationBonds[i].token == token &&
            amount >= _acceptableEscalationBonds[i].minAmount) {
            return true;
        }
    }
    return false;
}
```

---

## Task 16: Update Tests

**File:** `contracts/test/TOCRegistry.t.sol`

### New Test Scenarios

1. **TruthKeeper Registry Tests**
   - `test_AddWhitelistedTruthKeeper`
   - `test_RemoveWhitelistedTruthKeeper`
   - `test_AddWhitelistedResolver`
   - `test_TruthKeeperAddGuaranteedResolver`
   - `test_CalculateAccountabilityTier_System`
   - `test_CalculateAccountabilityTier_TKGuaranteed`
   - `test_CalculateAccountabilityTier_Permissionless`

2. **TOC Creation with TruthKeeper**
   - `test_CreateTOCWithTruthKeeper`
   - `test_TierSnapshotAtCreation`

3. **Round 1 Dispute Flow**
   - `test_DisputeCreatesRound1State`
   - `test_TruthKeeperResolvesDispute_Uphold`
   - `test_TruthKeeperResolvesDispute_Reject`
   - `test_TruthKeeperResolvesDispute_Cancel`
   - `test_TruthKeeperResolvesDispute_TooEarly`
   - `test_OnlyTruthKeeperCanResolveRound1`

4. **Round 2 Escalation Flow**
   - `test_ChallengeTruthKeeperDecision`
   - `test_EscalationRequiresHigherBond`
   - `test_AdminResolvesEscalation`
   - `test_FinalizeAfterTruthKeeper_NoChallenge`

5. **TruthKeeper Timeout**
   - `test_TruthKeeperTimeout_AutoEscalate`
   - `test_CannotEscalateBeforeTimeout`

6. **Bond Economics**
   - `test_BondSlash_50PercentToWinner`
   - `test_BondSlash_50PercentToContract`
   - `test_EscalationBondEconomics`

7. **TOO_EARLY Resolution**
   - `test_TooEarly_ReturnsToActive`
   - `test_TooEarly_BondDistribution`

---

## Task 17: Update Documentation

**File:** `docs/TOC_SYSTEM_DOCUMENTATION.md`

Add new sections:
- TruthKeeper System
- Two-Round Dispute Mechanism
- Accountability Tiers
- Escalation Flow
- Bond Economics (50/50 split)
- TOO_EARLY Resolution

---

## Implementation Order Summary

1. TOCTypes.sol - Enums (Task 1)
2. TOCTypes.sol - Structs (Task 2)
3. ITOCRegistry.sol - Events (Task 3)
4. ITOCRegistry.sol - Admin Functions (Task 4)
5. ITOCRegistry.sol - TruthKeeper Functions (Task 5)
6. ITOCRegistry.sol - TOC Creation (Task 6)
7. ITOCRegistry.sol - Dispute Functions (Task 7)
8. ITOCRegistry.sol - View Functions (Task 8)
9. TOCRegistry.sol - Storage (Task 9)
10. TOCRegistry.sol - Admin Functions (Task 10)
11. TOCRegistry.sol - TruthKeeper Functions (Task 11)
12. TOCRegistry.sol - TOC Creation (Task 12)
13. TOCRegistry.sol - Dispute Flow (Task 13)
14. TOCRegistry.sol - Bond Economics (Task 14)
15. TOCRegistry.sol - View Functions (Task 15)
16. Tests (Task 16)
17. Documentation (Task 17)
