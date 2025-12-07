// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "./POPTypes.sol";

/// @title IPOPRegistry
/// @notice Interface for the POP Registry contract
/// @dev Central contract managing POP lifecycle, resolvers, and disputes
interface IPOPRegistry {
    // ============ Events ============

    // Resolver management
    event ResolverRegistered(address indexed resolver, ResolverTrust trust, address indexed registeredBy);
    event ResolverTrustChanged(address indexed resolver, ResolverTrust oldTrust, ResolverTrust newTrust);

    // TruthKeeper registry
    event TruthKeeperWhitelisted(address indexed tk);
    event TruthKeeperRemovedFromWhitelist(address indexed tk);
    event TruthKeeperGuaranteeAdded(address indexed tk, address indexed resolver);
    event TruthKeeperGuaranteeRemoved(address indexed tk, address indexed resolver);

    // POP lifecycle
    event POPCreated(
        uint256 indexed popId,
        address indexed resolver,
        ResolverTrust trust,
        uint32 templateId,
        AnswerType answerType,
        POPState initialState,
        address indexed truthKeeper,
        AccountabilityTier tier
    );
    event POPApproved(uint256 indexed popId);
    event POPRejected(uint256 indexed popId, string reason);

    // Resolution
    event POPResolutionProposed(
        uint256 indexed popId,
        address indexed proposer,
        AnswerType answerType,
        uint256 disputeDeadline
    );
    event POPResolved(uint256 indexed popId, AnswerType answerType);
    event POPFinalized(uint256 indexed popId, AnswerType answerType);

    // Disputes
    event POPDisputed(
        uint256 indexed popId,
        address indexed disputer,
        string reason
    );
    event PostResolutionDisputeFiled(
        uint256 indexed popId,
        address indexed disputer,
        string reason
    );
    event DisputeResolved(
        uint256 indexed popId,
        DisputeResolution resolution,
        address indexed admin
    );
    event PostResolutionDisputeResolved(
        uint256 indexed popId,
        bool resultCorrected
    );
    event POPCancelled(uint256 indexed popId, string reason);

    // TruthKeeper dispute flow
    event TruthKeeperDisputeResolved(
        uint256 indexed popId,
        address indexed tk,
        DisputeResolution resolution
    );
    event TruthKeeperDecisionChallenged(
        uint256 indexed popId,
        address indexed challenger,
        string reason
    );
    event TruthKeeperTimedOut(
        uint256 indexed popId,
        address indexed tk
    );
    event EscalationResolved(
        uint256 indexed popId,
        DisputeResolution resolution,
        address indexed admin
    );

    // Bonds
    event ResolutionBondDeposited(uint256 indexed popId, address indexed proposer, address token, uint256 amount);
    event ResolutionBondReturned(uint256 indexed popId, address indexed to, address token, uint256 amount);
    event DisputeBondDeposited(uint256 indexed popId, address indexed disputer, address token, uint256 amount);
    event DisputeBondReturned(uint256 indexed popId, address indexed to, address token, uint256 amount);
    event BondSlashed(uint256 indexed popId, address indexed from, address token, uint256 amount);

    // ============ Resolver Registration ============

    /// @notice Register a resolver (permissionless, must be contract)
    /// @param resolver Address of the resolver contract
    function registerResolver(address resolver) external;

    /// @notice Set resolver trust level (admin only)
    /// @param resolver Address of the resolver
    /// @param trust New trust level
    function setResolverTrust(address resolver, ResolverTrust trust) external;

    // ============ Admin Functions ============

    /// @notice Add an acceptable bond token/amount for resolutions
    /// @param token Token address (address(0) for native)
    /// @param minAmount Minimum amount required
    function addAcceptableResolutionBond(address token, uint256 minAmount) external;

    /// @notice Add an acceptable bond token/amount for disputes
    /// @param token Token address (address(0) for native)
    /// @param minAmount Minimum amount required
    function addAcceptableDisputeBond(address token, uint256 minAmount) external;

    /// @notice Set default dispute window for resolvers that don't specify one
    /// @param duration Duration in seconds
    function setDefaultDisputeWindow(uint256 duration) external;

    /// @notice Add a TruthKeeper to the system whitelist
    /// @param tk Address of the TruthKeeper
    function addWhitelistedTruthKeeper(address tk) external;

    /// @notice Remove a TruthKeeper from the system whitelist
    /// @param tk Address of the TruthKeeper
    function removeWhitelistedTruthKeeper(address tk) external;

    /// @notice Add an acceptable bond token/amount for escalations (Round 2)
    /// @param token Token address (address(0) for native)
    /// @param minAmount Minimum amount required (should be higher than dispute bonds)
    function addAcceptableEscalationBond(address token, uint256 minAmount) external;

    // ============ TruthKeeper Functions ============

    /// @notice TruthKeeper adds a resolver to their guaranteed list
    /// @param resolver Address of resolver they guarantee to handle
    function addGuaranteedResolver(address resolver) external;

    /// @notice TruthKeeper removes a resolver from their guaranteed list
    /// @param resolver Address of resolver to remove
    function removeGuaranteedResolver(address resolver) external;

    /// @notice TruthKeeper resolves a Round 1 dispute
    /// @param popId The disputed POP
    /// @param resolution How to resolve (UPHOLD_DISPUTE, REJECT_DISPUTE, CANCEL_POP, TOO_EARLY)
    /// @param correctedBooleanResult Corrected boolean result (if upholding)
    /// @param correctedNumericResult Corrected numeric result (if upholding)
    /// @param correctedGenericResult Corrected generic result (if upholding)
    function resolveTruthKeeperDispute(
        uint256 popId,
        DisputeResolution resolution,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult
    ) external;

    // ============ POP Lifecycle ============

    /// @notice Create a new POP
    /// @param resolver Address of the resolver contract
    /// @param templateId Template ID within the resolver
    /// @param payload Creation parameters encoded for the template
    /// @param disputeWindow Pre-resolution dispute window duration in seconds (0 for immediate resolution)
    /// @param truthKeeperWindow Time for TruthKeeper to decide Round 1 disputes
    /// @param escalationWindow Time to challenge TruthKeeper decision
    /// @param postResolutionWindow Post-resolution dispute window duration in seconds (0 for no post-resolution disputes)
    /// @param truthKeeper Address of the TruthKeeper for this POP
    /// @return popId The unique identifier for the new POP
    function createPOP(
        address resolver,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
    ) external returns (uint256 popId);

    /// @notice Propose resolution for a POP (requires bond)
    /// @param popId The POP to resolve
    /// @param bondToken Token to use for bond (must be acceptable)
    /// @param bondAmount Amount of bond to post
    /// @param payload Resolver-specific resolution data
    function resolvePOP(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) external payable;

    /// @notice Finalize a POP after dispute window expires
    /// @param popId The POP to finalize
    function finalizePOP(uint256 popId) external;

    // ============ Dispute System ============

    /// @notice Dispute a proposed or finalized resolution
    /// @param popId The POP to dispute
    /// @param bondToken Token to use for dispute bond
    /// @param bondAmount Amount of bond to post
    /// @param reason Reason for the dispute
    /// @param evidenceURI IPFS/Arweave link for detailed evidence
    /// @param proposedBooleanResult Disputer's proposed correct boolean result (optional)
    /// @param proposedNumericResult Disputer's proposed correct numeric result (optional)
    /// @param proposedGenericResult Disputer's proposed correct generic result (optional)
    function dispute(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bool proposedBooleanResult,
        int256 proposedNumericResult,
        bytes calldata proposedGenericResult
    ) external payable;

    /// @notice Challenge a TruthKeeper's decision (escalate to Round 2)
    /// @param popId The POP with TK decision to challenge
    /// @param bondToken Token for escalation bond (must be acceptable)
    /// @param bondAmount Amount of escalation bond (higher than dispute bond)
    /// @param reason Reason for challenging TK decision
    /// @param evidenceURI IPFS/Arweave link for detailed evidence
    /// @param proposedBooleanResult Challenger's proposed boolean result
    /// @param proposedNumericResult Challenger's proposed numeric result
    /// @param proposedGenericResult Challenger's proposed generic result
    function challengeTruthKeeperDecision(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bool proposedBooleanResult,
        int256 proposedNumericResult,
        bytes calldata proposedGenericResult
    ) external payable;

    /// @notice Finalize a POP after TruthKeeper decision (if no challenge)
    /// @param popId The POP to finalize
    function finalizeAfterTruthKeeper(uint256 popId) external;

    /// @notice Escalate to Round 2 if TruthKeeper times out
    /// @param popId The POP where TK timed out
    function escalateTruthKeeperTimeout(uint256 popId) external;

    /// @notice Admin resolves a Round 2 escalation
    /// @param popId The escalated POP
    /// @param resolution How to resolve the escalation
    /// @param correctedBooleanResult Admin's corrected boolean result
    /// @param correctedNumericResult Admin's corrected numeric result
    /// @param correctedGenericResult Admin's corrected generic result
    function resolveEscalation(
        uint256 popId,
        DisputeResolution resolution,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult
    ) external;

    /// @notice Admin resolves a dispute
    /// @param popId The disputed POP
    /// @param resolution How to resolve the dispute
    /// @param correctedBooleanResult Admin's corrected boolean result (used if upholding, can override disputer's proposal)
    /// @param correctedNumericResult Admin's corrected numeric result (used if upholding, can override disputer's proposal)
    /// @param correctedGenericResult Admin's corrected generic result (used if upholding, can override disputer's proposal)
    function resolveDispute(
        uint256 popId,
        DisputeResolution resolution,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult
    ) external;

    // ============ Resolver Callbacks ============

    /// @notice Called by resolver to approve a PENDING POP
    /// @param popId The POP to approve
    function approvePOP(uint256 popId) external;

    /// @notice Called by resolver to reject a PENDING POP
    /// @param popId The POP to reject
    /// @param reason Reason for rejection
    function rejectPOP(uint256 popId, string calldata reason) external;

    // ============ View Functions ============

    /// @notice Get POP state
    /// @param popId The POP identifier
    /// @return The POP struct
    function getPOP(uint256 popId) external view returns (POP memory);

    /// @notice Get extended POP info with resolver context
    /// @param popId The POP identifier
    /// @return info The extended POP information
    function getPOPInfo(uint256 popId) external view returns (POPInfo memory info);

    /// @notice Get POP details (proxied to resolver)
    /// @param popId The POP identifier
    /// @return templateId The template used
    /// @return creationPayload The creation parameters
    function getPopDetails(uint256 popId)
        external
        view
        returns (uint32 templateId, bytes memory creationPayload);

    /// @notice Get human-readable question (proxied to resolver)
    /// @param popId The POP identifier
    /// @return question The formatted question
    function getPopQuestion(uint256 popId)
        external
        view
        returns (string memory question);

    /// @notice Get resolver trust level
    /// @param resolver Address to check
    /// @return trust The resolver trust level (NONE if not registered)
    function getResolverTrust(address resolver) external view returns (ResolverTrust trust);

    /// @notice Check if resolver is registered (trust > NONE)
    /// @param resolver Address to check
    /// @return True if registered
    function isRegisteredResolver(address resolver) external view returns (bool);

    /// @notice Get resolver configuration
    /// @param resolver Address of resolver
    /// @return config The resolver configuration
    function getResolverConfig(address resolver) external view returns (ResolverConfig memory config);

    /// @notice Get all registered resolvers
    /// @return Array of resolver addresses
    function getRegisteredResolvers() external view returns (address[] memory);

    /// @notice Get count of registered resolvers
    /// @return count Number of resolvers
    function getResolverCount() external view returns (uint256 count);

    /// @notice Get dispute info for a POP
    /// @param popId The POP identifier
    /// @return info The dispute information
    function getDisputeInfo(uint256 popId) external view returns (DisputeInfo memory info);

    /// @notice Get resolution info for a POP
    /// @param popId The POP identifier
    /// @return info The resolution information
    function getResolutionInfo(uint256 popId) external view returns (ResolutionInfo memory info);

    /// @notice Get the result of a resolved POP
    /// @param popId The POP identifier
    /// @return result The POP result (check isResolved before using)
    function getPOPResult(uint256 popId) external view returns (POPResult memory result);

    /// @notice Get the boolean result for a POP (only valid if answerType == BOOLEAN)
    /// @param popId The POP identifier
    /// @return result The boolean result
    function getBooleanResult(uint256 popId) external view returns (bool result);

    /// @notice Get the numeric result for a POP (only valid if answerType == NUMERIC)
    /// @param popId The POP identifier
    /// @return result The numeric result
    function getNumericResult(uint256 popId) external view returns (int256 result);

    /// @notice Get the generic result for a POP (only valid if answerType == GENERIC)
    /// @param popId The POP identifier
    /// @return result The generic result as bytes
    function getGenericResult(uint256 popId) external view returns (bytes memory result);

    /// @notice Check if bond is acceptable for resolution
    /// @param token Token address
    /// @param amount Amount
    /// @return True if acceptable
    function isAcceptableResolutionBond(address token, uint256 amount) external view returns (bool);

    /// @notice Check if bond is acceptable for dispute
    /// @param token Token address
    /// @param amount Amount
    /// @return True if acceptable
    function isAcceptableDisputeBond(address token, uint256 amount) external view returns (bool);

    /// @notice Get the next POP ID that will be assigned
    /// @return The next POP ID
    function nextPopId() external view returns (uint256);

    /// @notice Get the default dispute window duration
    /// @return Duration in seconds
    function defaultDisputeWindow() external view returns (uint256);

    // ============ Flexible Dispute Window View Functions ============

    /// @notice Check if a POP is fully finalized (resolved and all dispute windows closed)
    /// @param popId The POP identifier
    /// @return True if fully finalized
    function isFullyFinalized(uint256 popId) external view returns (bool);

    /// @notice Check if a POP has been contested via post-resolution dispute
    /// @param popId The POP identifier
    /// @return True if contested
    function isContested(uint256 popId) external view returns (bool);

    /// @notice Check if a POP has a corrected result (post-resolution dispute was upheld)
    /// @param popId The POP identifier
    /// @return True if has corrected result
    function hasCorrectedResult(uint256 popId) external view returns (bool);

    /// @notice Get the corrected boolean result (only valid if hasCorrectedResult is true)
    /// @param popId The POP identifier
    /// @return result The corrected boolean result
    function getCorrectedBooleanResult(uint256 popId) external view returns (bool result);

    /// @notice Get the corrected numeric result (only valid if hasCorrectedResult is true)
    /// @param popId The POP identifier
    /// @return result The corrected numeric result
    function getCorrectedNumericResult(uint256 popId) external view returns (int256 result);

    /// @notice Get the corrected generic result (only valid if hasCorrectedResult is true)
    /// @param popId The POP identifier
    /// @return result The corrected generic result
    function getCorrectedGenericResult(uint256 popId) external view returns (bytes memory result);

    // ============ TruthKeeper View Functions ============

    /// @notice Check if an address is a whitelisted TruthKeeper
    /// @param tk Address to check
    /// @return True if whitelisted
    function isWhitelistedTruthKeeper(address tk) external view returns (bool);

    /// @notice Get list of resolvers a TruthKeeper guarantees
    /// @param tk TruthKeeper address
    /// @return Array of resolver addresses
    function getTruthKeeperGuaranteedResolvers(address tk) external view returns (address[] memory);

    /// @notice Check if TruthKeeper guarantees a specific resolver
    /// @param tk TruthKeeper address
    /// @param resolver Resolver address
    /// @return True if TK guarantees this resolver
    function isTruthKeeperGuaranteedResolver(address tk, address resolver) external view returns (bool);

    /// @notice Get escalation info for a POP
    /// @param popId The POP identifier
    /// @return info The escalation information
    function getEscalationInfo(uint256 popId) external view returns (EscalationInfo memory info);

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

    // ============ Consumer Result Functions ============

    /// @notice Get result with full resolution context
    /// @param popId The POP identifier
    /// @return result The extensive result with context
    function getExtensiveResult(uint256 popId) external view returns (ExtensiveResult memory result);

    /// @notice Get result only if fully finalized (reverts otherwise)
    /// @param popId The POP identifier
    /// @return result The extensive result with context
    function getExtensiveResultStrict(uint256 popId) external view returns (ExtensiveResult memory result);
}
