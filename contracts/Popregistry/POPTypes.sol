// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/// @title POPTypes
/// @notice Shared types for the POP (Prediction Option) system

/// @notice States a POP can be in throughout its lifecycle
enum POPState {
    NONE,           // Default/uninitialized
    PENDING,        // Created, awaiting resolver approval
    REJECTED,       // Resolver rejected during creation
    ACTIVE,         // Approved, markets can trade
    RESOLVING,      // Outcome proposed, dispute window open
    DISPUTED,       // Dispute raised, admin reviewing
    RESOLVED,       // Final outcome set, immutable
    CANCELLED       // Admin cancelled, markets should refund
}

/// @notice Types of answers a POP can have
enum AnswerType {
    NONE,       // Default/uninitialized
    BOOLEAN,    // True/False answer
    NUMERIC,    // int256 answer (supports negative, prices, scores, etc.)
    GENERIC     // bytes answer (arbitrary data, hashes, strings, etc.)
}

/// @notice Resolution options for admin when handling disputes
enum DisputeResolution {
    UPHOLD_DISPUTE,  // Disputer was right, override outcome
    REJECT_DISPUTE,  // Original outcome stands
    CANCEL_POP       // Entire POP is invalid, refund all
}

/// @notice Types of resolvers in the system
enum ResolverType {
    NONE,       // Default/unregistered
    SYSTEM,     // Official ecosystem resolvers
    PUBLIC,     // Third-party resolvers
    DEPRECATED  // Deactivated resolvers (soft deprecation)
}

/// @notice Core POP data stored in registry
struct POP {
    address resolver;           // Which resolver manages this POP
    POPState state;             // Current state
    AnswerType answerType;      // Type of answer this POP will return
    uint256 resolutionTime;     // Timestamp when resolved
    uint256 disputeDeadline;    // End of dispute window
}

/// @notice Result data for a resolved POP, stored separately from POP lifecycle
/// @dev Only one of booleanResult/numericResult/genericResult is valid based on answerType
struct POPResult {
    AnswerType answerType;      // Which type of answer this POP returns
    bool isResolved;            // Whether a result has been set
    bool booleanResult;         // Result if answerType == BOOLEAN
    int256 numericResult;       // Result if answerType == NUMERIC
    bytes genericResult;        // Result if answerType == GENERIC
}

/// @notice Information about a dispute
struct DisputeInfo {
    address disputer;           // Who disputed
    address bondToken;          // Token used for dispute bond
    uint256 bondAmount;         // Amount of bond held
    string reason;              // Dispute reason
}

/// @notice Information about a resolution proposal
struct ResolutionInfo {
    address proposer;           // Who proposed the resolution
    address bondToken;          // Token used for resolution bond
    uint256 bondAmount;         // Amount of bond held
    // Proposed outcome (type determined by POP's answerType)
    bool proposedBooleanOutcome;
    int256 proposedNumericOutcome;
    bytes proposedGenericOutcome;
}

/// @notice Configuration for system resolvers
struct SystemResolverConfig {
    uint256 disputeWindow;      // Seconds for dispute period (0 = use default)
    bool isActive;              // Whether resolver is active
    uint256 registeredAt;       // Timestamp when registered
    address registeredBy;       // Who registered it
}

/// @notice Configuration for public resolvers
struct PublicResolverConfig {
    uint256 disputeWindow;      // Seconds for dispute period (0 = use default)
    bool isActive;              // Whether resolver is active
    uint256 registeredAt;       // Timestamp when registered
    address registeredBy;       // Who registered it
}

/// @notice Extended POP info with resolver context
struct POPInfo {
    // POP fields
    address resolver;
    POPState state;
    AnswerType answerType;
    uint256 resolutionTime;
    uint256 disputeDeadline;
    // Result (only valid when state == RESOLVED)
    bool isResolved;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;
    // Resolver context
    ResolverType resolverType;
    uint256 resolverId;
    uint256 disputeWindow;
    bool resolverIsActive;
}

/// @notice Bond requirement for resolution or dispute
struct BondRequirement {
    address token;              // address(0) = native ETH
    uint256 minAmount;          // Minimum amount required
}
