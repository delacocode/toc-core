// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/// @title TOCTypes
/// @notice Shared types for the TOC (Truth On Chain) system

/// @notice States a TOC can be in throughout its lifecycle
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

/// @notice Types of answers a TOC can have
enum AnswerType {
    NONE,       // Default/uninitialized
    BOOLEAN,    // True/False answer
    NUMERIC,    // int256 answer (supports negative, prices, scores, etc.)
    GENERIC     // bytes answer (arbitrary data, hashes, strings, etc.)
}

/// @notice Resolution options when handling disputes
enum DisputeResolution {
    UPHOLD_DISPUTE,  // Disputer was right, override outcome
    REJECT_DISPUTE,  // Original outcome stands
    CANCEL_TOC,      // Entire TOC is invalid, refund all
    TOO_EARLY        // Event hasn't occurred yet, return to ACTIVE
}

/// @notice Trust level for resolvers
enum ResolverTrust {
    NONE,           // Not registered (default)
    RESOLVER,       // Registered, no system guarantees
    VERIFIED,       // Admin reviewed, some assurance
    SYSTEM          // Full system backing
}

/// @notice Accountability tier for a TOC (snapshot at creation)
enum AccountabilityTier {
    NONE,           // Default/uninitialized
    RESOLVER,       // No guarantees - creator's risk
    TK_GUARANTEED,  // TruthKeeper guarantees response
    SYSTEM          // System takes full accountability
}

/// @notice Phase when a dispute was filed
enum DisputePhase {
    NONE,           // No dispute filed
    PRE_RESOLUTION, // Dispute filed during RESOLVING state (before finalization)
    POST_RESOLUTION // Dispute filed after RESOLVED state
}

/// @notice Response from TruthKeeper when a TOC is assigned
enum TKApprovalResponse {
    APPROVE,        // Accept responsibility, tier upgrades
    REJECT_SOFT,    // Decline but allow TOC as RESOLVER
    REJECT_HARD     // Decline and revert TOC creation
}

/// @notice Core TOC data stored in registry
struct TOC {
    address creator;                // Who created this TOC
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

/// @notice Result data for a resolved TOC
/// @dev Result is ABI-encoded based on answerType. Use TOCResultCodec to decode.
struct TOCResult {
    AnswerType answerType;      // Which type of answer this TOC returns
    bool isResolved;            // Whether a result has been set
    bytes result;               // ABI-encoded result (use TOCResultCodec to decode)
}

/// @notice Information about a dispute
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

    // Disputer's proposed correction (optional, ABI-encoded)
    bytes proposedResult;

    // TruthKeeper decision (Round 1)
    DisputeResolution tkDecision;   // TK's decision (if decided)
    uint256 tkDecidedAt;            // Timestamp when TK decided (0 if pending)
}

/// @notice Information about a Round 2 escalation (challenging TruthKeeper decision)
struct EscalationInfo {
    address challenger;             // Who challenged the TK decision
    address bondToken;              // Token used for escalation bond
    uint256 bondAmount;             // Amount of escalation bond (higher than Round 1)
    string reason;                  // Reason for challenging TK
    string evidenceURI;             // IPFS/Arweave link for detailed evidence
    uint256 filedAt;                // Timestamp when escalation was filed
    uint256 resolvedAt;             // Timestamp when admin resolved (0 if pending)

    // Challenger's proposed correction (optional, ABI-encoded)
    bytes proposedResult;
}

/// @notice Information about a resolution proposal
struct ResolutionInfo {
    address proposer;           // Who proposed the resolution
    address bondToken;          // Token used for resolution bond
    uint256 bondAmount;         // Amount of bond held
    bytes proposedResult;       // ABI-encoded proposed outcome
}

/// @notice Configuration for a resolver
struct ResolverConfig {
    ResolverTrust trust;        // Trust level
    uint256 registeredAt;       // Timestamp when registered
    address registeredBy;       // Who registered it
}

/// @notice Extended TOC info with resolver context
struct TOCInfo {
    // TOC fields
    address creator;
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
    bytes result;               // ABI-encoded result (use TOCResultCodec to decode)
    bool hasCorrectedResult;    // Whether result was corrected via dispute

    // Resolver context
    ResolverTrust resolverTrust;
}

/// @notice Bond requirement for resolution or dispute
struct BondRequirement {
    address token;              // address(0) = native ETH
    uint256 minAmount;          // Minimum amount required
}

/// @notice Result with full resolution context for consumers
struct ExtensiveResult {
    // The answer
    AnswerType answerType;
    bytes result;               // ABI-encoded result (use TOCResultCodec to decode)

    // Resolution context
    bool isFinalized;           // State == RESOLVED
    bool wasDisputed;           // Had a dispute filed
    bool wasCorrected;          // Dispute upheld, result changed
    uint256 resolvedAt;         // Timestamp of resolution
    AccountabilityTier tier;    // SYSTEM/TK_GUARANTEED/RESOLVER
    ResolverTrust resolverTrust; // Trust level of resolver
}

/// @notice Categories of protocol fees for tracking
enum FeeCategory {
    CREATION,   // Fees from TOC creation
    SLASHING    // Fees from bond slashing
}
