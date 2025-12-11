// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

// ============================================================================
// TOC Consumer Interface
// ============================================================================
// Single-file interface for protocols consuming TOC (Truth On Chain).
// Copy this file to your project to integrate with TOC Registry.
// ============================================================================

// ============ Enums ============

/// @notice States a TOC can be in throughout its lifecycle
enum TOCState {
    NONE,               // Default/uninitialized
    PENDING,            // Created, awaiting resolver approval
    REJECTED,           // Resolver rejected during creation
    ACTIVE,             // Approved, markets can trade
    RESOLVING,          // Outcome proposed, dispute window open
    DISPUTED_ROUND_1,   // Dispute raised, TruthKeeper reviewing
    DISPUTED_ROUND_2,   // TK decision challenged, Admin reviewing
    RESOLVED,           // Final outcome set, immutable
    CANCELLED           // Admin cancelled, markets should refund
}

/// @notice Types of answers a TOC can have
enum AnswerType {
    NONE,       // Default/uninitialized
    BOOLEAN,    // True/False answer
    NUMERIC,    // int256 answer (prices, scores, etc.)
    GENERIC     // bytes answer (arbitrary data)
}

/// @notice Trust level for resolvers
enum ResolverTrust {
    NONE,       // Not registered
    RESOLVER,   // Registered, no system guarantees
    VERIFIED,   // Admin reviewed
    SYSTEM      // Full system backing
}

/// @notice Accountability tier for a TOC (snapshot at creation)
enum AccountabilityTier {
    NONE,           // Default/uninitialized
    RESOLVER,       // No guarantees - creator's risk
    TK_GUARANTEED,  // TruthKeeper guarantees response
    SYSTEM          // System takes full accountability
}

// ============ Structs ============

/// @notice Core TOC data
struct TOC {
    address resolver;
    TOCState state;
    AnswerType answerType;
    uint256 resolutionTime;
    uint256 disputeWindow;
    uint256 truthKeeperWindow;
    uint256 escalationWindow;
    uint256 postResolutionWindow;
    uint256 disputeDeadline;
    uint256 truthKeeperDeadline;
    uint256 escalationDeadline;
    uint256 postDisputeDeadline;
    address truthKeeper;
    AccountabilityTier tierAtCreation;
}

/// @notice Result with full resolution context for consumers
struct ExtensiveResult {
    AnswerType answerType;
    bytes result;               // ABI-encoded result (use TOCResultCodec to decode)
    bool isFinalized;           // State == RESOLVED
    bool wasDisputed;           // Had a dispute filed
    bool wasCorrected;          // Dispute upheld, result changed
    uint256 resolvedAt;         // Timestamp of resolution
    AccountabilityTier tier;    // SYSTEM/TK_GUARANTEED/RESOLVER
    ResolverTrust resolverTrust;
}

// ============ Result Codec ============

/// @title TOCResultCodec
/// @notice Encoding/decoding utilities for TOC results
library TOCResultCodec {
    function encodeBoolean(bool value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    function encodeNumeric(int256 value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    function decodeBoolean(bytes memory data) internal pure returns (bool) {
        return abi.decode(data, (bool));
    }

    function decodeNumeric(bytes memory data) internal pure returns (int256) {
        return abi.decode(data, (int256));
    }
}

// ============ Registry Interface ============

/// @title ITOCRegistry
/// @notice Consumer-focused interface for TOC Registry
/// @dev Subset of full interface - includes only functions needed by consumers
interface ITOCRegistry {
    // ============ TOC Creation ============

    /// @notice Create a new TOC
    /// @param resolver Address of the resolver contract
    /// @param templateId Template ID within the resolver
    /// @param payload Creation parameters encoded for the template
    /// @param disputeWindow Pre-resolution dispute window (seconds)
    /// @param truthKeeperWindow Time for TruthKeeper to decide disputes (seconds)
    /// @param escalationWindow Time to challenge TruthKeeper decision (seconds)
    /// @param postResolutionWindow Post-resolution dispute window (seconds, 0 to disable)
    /// @param truthKeeper Address of the TruthKeeper for this TOC
    /// @return tocId The unique identifier for the new TOC
    function createTOC(
        address resolver,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
    ) external payable returns (uint256 tocId);

    // ============ Reading TOC State ============

    /// @notice Get TOC data
    /// @param tocId The TOC identifier
    /// @return The TOC struct
    function getTOC(uint256 tocId) external view returns (TOC memory);

    /// @notice Get the ABI-encoded result for a TOC
    /// @param tocId The TOC identifier
    /// @return result The ABI-encoded result
    function getResult(uint256 tocId) external view returns (bytes memory result);

    /// @notice Get result with full resolution context
    /// @param tocId The TOC identifier
    /// @return result The extensive result with context
    function getExtensiveResult(uint256 tocId) external view returns (ExtensiveResult memory result);

    /// @notice Get result only if fully finalized (reverts otherwise)
    /// @param tocId The TOC identifier
    /// @return result The extensive result with context
    function getExtensiveResultStrict(uint256 tocId) external view returns (ExtensiveResult memory result);

    /// @notice Get human-readable question (proxied to resolver)
    /// @param tocId The TOC identifier
    /// @return question The formatted question
    function getTocQuestion(uint256 tocId) external view returns (string memory question);

    /// @notice Check if a TOC is fully finalized (resolved + all windows closed)
    /// @param tocId The TOC identifier
    /// @return True if fully finalized
    function isFullyFinalized(uint256 tocId) external view returns (bool);

    /// @notice Check if a TOC has a corrected result
    /// @param tocId The TOC identifier
    /// @return True if has corrected result
    function hasCorrectedResult(uint256 tocId) external view returns (bool);

    /// @notice Get the next TOC ID that will be assigned
    /// @return The next TOC ID
    function nextTocId() external view returns (uint256);

    // ============ Fee Information ============

    /// @notice Get the total creation fee for a TOC
    /// @param resolver The resolver address
    /// @param templateId The template ID
    /// @return protocolFee The protocol fee portion
    /// @return resolverFee The resolver fee portion
    /// @return total The total fee required
    function getCreationFee(
        address resolver,
        uint32 templateId
    ) external view returns (uint256 protocolFee, uint256 resolverFee, uint256 total);
}

// ============ OptimisticResolver Payloads ============
// These structs show how to encode payloads for OptimisticResolver templates.
// Use abi.encode(payload) when calling createTOC().

/// @notice Payload for Template 0: Arbitrary Question
struct ArbitraryPayload {
    string question;
    string description;
    string resolutionSource;
    uint256 resolutionTime;
}

/// @notice Types of sports questions for Template 1
enum SportQuestionType {
    WINNER,      // Which team wins?
    SPREAD,      // Does home team cover spread?
    OVER_UNDER   // Is total score over/under line?
}

/// @notice Payload for Template 1: Sports Outcome
struct SportsPayload {
    string league;
    string homeTeam;
    string awayTeam;
    uint256 gameTime;
    SportQuestionType questionType;
    int256 line; // For spread/over-under (scaled 1e18)
}

/// @notice Payload for Template 2: Event Occurrence
struct EventPayload {
    string eventDescription;
    string verificationSource;
    uint256 deadline;
}

/// @notice Answer payload for resolution proposals
struct AnswerPayload {
    bool answer;
    string justification;
}
