// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "./TOCTypes.sol";

/// @title ITOCRegistry
/// @notice Interface for the TOC Registry contract
/// @dev Central contract managing TOC lifecycle, resolvers, and disputes
interface ITOCRegistry {
    // ============ Events ============

    // Resolver management
    event ResolverRegistered(address indexed resolver, ResolverTrust trust, address indexed registeredBy);
    event ResolverTrustChanged(address indexed resolver, ResolverTrust oldTrust, ResolverTrust newTrust);

    // TruthKeeper registry
    event TruthKeeperWhitelisted(address indexed tk);
    event TruthKeeperRemovedFromWhitelist(address indexed tk);
    event TruthKeeperApproved(uint256 indexed tocId, address indexed tk);
    event TruthKeeperSoftRejected(uint256 indexed tocId, address indexed tk);

    // TOC lifecycle
    event TOCCreated(
        uint256 indexed tocId,
        address indexed resolver,
        ResolverTrust trust,
        uint32 templateId,
        AnswerType answerType,
        TOCState initialState,
        address indexed truthKeeper,
        AccountabilityTier tier
    );
    event TOCApproved(uint256 indexed tocId);
    event TOCRejected(uint256 indexed tocId, string reason);

    // Resolution
    event TOCResolutionProposed(
        uint256 indexed tocId,
        address indexed proposer,
        AnswerType answerType,
        uint256 disputeDeadline
    );
    event TOCResolved(uint256 indexed tocId, AnswerType answerType);
    event TOCFinalized(uint256 indexed tocId, AnswerType answerType);

    // Disputes
    event TOCDisputed(
        uint256 indexed tocId,
        address indexed disputer,
        string reason
    );
    event PostResolutionDisputeFiled(
        uint256 indexed tocId,
        address indexed disputer,
        string reason
    );
    event DisputeResolved(
        uint256 indexed tocId,
        DisputeResolution resolution,
        address indexed admin
    );
    event PostResolutionDisputeResolved(
        uint256 indexed tocId,
        bool resultCorrected
    );
    event TOCCancelled(uint256 indexed tocId, string reason);

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

    // Bonds
    event ResolutionBondDeposited(uint256 indexed tocId, address indexed proposer, address token, uint256 amount);
    event ResolutionBondReturned(uint256 indexed tocId, address indexed to, address token, uint256 amount);
    event DisputeBondDeposited(uint256 indexed tocId, address indexed disputer, address token, uint256 amount);
    event DisputeBondReturned(uint256 indexed tocId, address indexed to, address token, uint256 amount);
    event BondSlashed(uint256 indexed tocId, address indexed from, address token, uint256 amount);

    // Fee events
    event TreasurySet(address indexed treasury);
    event ProtocolFeeUpdated(uint256 minimum, uint256 standard);
    event TKShareUpdated(AccountabilityTier indexed tier, uint256 basisPoints);
    event ResolverFeeSet(address indexed resolver, uint32 indexed templateId, uint256 amount);
    event CreationFeesCollected(uint256 indexed tocId, uint256 protocolFee, uint256 tkFee, uint256 resolverFee);
    event SlashingFeesCollected(uint256 indexed tocId, uint256 protocolFee, uint256 tkFee);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 creationFees, uint256 slashingFees);
    event TKFeesWithdrawn(address indexed tk, uint256 amount);
    event ResolverFeeClaimed(address indexed resolver, uint256 indexed tocId, uint256 amount);

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

    /// @notice TruthKeeper resolves a Round 1 dispute
    /// @param tocId The disputed TOC
    /// @param resolution How to resolve (UPHOLD_DISPUTE, REJECT_DISPUTE, CANCEL_TOC, TOO_EARLY)
    /// @param correctedResult ABI-encoded corrected result (if upholding)
    function resolveTruthKeeperDispute(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external;

    // ============ TOC Lifecycle ============

    /// @notice Create a new TOC
    /// @param resolver Address of the resolver contract
    /// @param templateId Template ID within the resolver
    /// @param payload Creation parameters encoded for the template
    /// @param disputeWindow Pre-resolution dispute window duration in seconds (0 for immediate resolution)
    /// @param truthKeeperWindow Time for TruthKeeper to decide Round 1 disputes
    /// @param escalationWindow Time to challenge TruthKeeper decision
    /// @param postResolutionWindow Post-resolution dispute window duration in seconds (0 for no post-resolution disputes)
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
    ) external returns (uint256 tocId);

    /// @notice Propose resolution for a TOC (requires bond)
    /// @param tocId The TOC to resolve
    /// @param bondToken Token to use for bond (must be acceptable)
    /// @param bondAmount Amount of bond to post
    /// @param payload Resolver-specific resolution data
    function resolveTOC(
        uint256 tocId,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) external payable;

    /// @notice Finalize a TOC after dispute window expires
    /// @param tocId The TOC to finalize
    function finalizeTOC(uint256 tocId) external;

    // ============ Dispute System ============

    /// @notice Dispute a proposed or finalized resolution
    /// @param tocId The TOC to dispute
    /// @param bondToken Token to use for dispute bond
    /// @param bondAmount Amount of bond to post
    /// @param reason Reason for the dispute
    /// @param evidenceURI IPFS/Arweave link for detailed evidence
    /// @param proposedResult ABI-encoded disputer's proposed correct result (optional)
    function dispute(
        uint256 tocId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bytes calldata proposedResult
    ) external payable;

    /// @notice Challenge a TruthKeeper's decision (escalate to Round 2)
    /// @param tocId The TOC with TK decision to challenge
    /// @param bondToken Token for escalation bond (must be acceptable)
    /// @param bondAmount Amount of escalation bond (higher than dispute bond)
    /// @param reason Reason for challenging TK decision
    /// @param evidenceURI IPFS/Arweave link for detailed evidence
    /// @param proposedResult ABI-encoded challenger's proposed result
    function challengeTruthKeeperDecision(
        uint256 tocId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bytes calldata proposedResult
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
    /// @param correctedResult ABI-encoded admin's corrected result
    function resolveEscalation(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external;

    /// @notice Admin resolves a dispute
    /// @param tocId The disputed TOC
    /// @param resolution How to resolve the dispute
    /// @param correctedResult ABI-encoded admin's corrected result (used if upholding, can override disputer's proposal)
    function resolveDispute(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external;

    // ============ Resolver Callbacks ============

    /// @notice Called by resolver to approve a PENDING TOC
    /// @param tocId The TOC to approve
    function approveTOC(uint256 tocId) external;

    /// @notice Called by resolver to reject a PENDING TOC
    /// @param tocId The TOC to reject
    /// @param reason Reason for rejection
    function rejectTOC(uint256 tocId, string calldata reason) external;

    // ============ View Functions ============

    /// @notice Get TOC state
    /// @param tocId The TOC identifier
    /// @return The TOC struct
    function getTOC(uint256 tocId) external view returns (TOC memory);

    /// @notice Get extended TOC info with resolver context
    /// @param tocId The TOC identifier
    /// @return info The extended TOC information
    function getTOCInfo(uint256 tocId) external view returns (TOCInfo memory info);

    /// @notice Get TOC details (proxied to resolver)
    /// @param tocId The TOC identifier
    /// @return templateId The template used
    /// @return creationPayload The creation parameters
    function getTocDetails(uint256 tocId)
        external
        view
        returns (uint32 templateId, bytes memory creationPayload);

    /// @notice Get human-readable question (proxied to resolver)
    /// @param tocId The TOC identifier
    /// @return question The formatted question
    function getTocQuestion(uint256 tocId)
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

    /// @notice Get dispute info for a TOC
    /// @param tocId The TOC identifier
    /// @return info The dispute information
    function getDisputeInfo(uint256 tocId) external view returns (DisputeInfo memory info);

    /// @notice Get resolution info for a TOC
    /// @param tocId The TOC identifier
    /// @return info The resolution information
    function getResolutionInfo(uint256 tocId) external view returns (ResolutionInfo memory info);

    /// @notice Get the result of a resolved TOC
    /// @param tocId The TOC identifier
    /// @return result The TOC result (check isResolved before using)
    function getTOCResult(uint256 tocId) external view returns (TOCResult memory result);

    /// @notice Get the ABI-encoded result for a TOC
    /// @dev Use TOCResultCodec to decode based on answerType
    /// @param tocId The TOC identifier
    /// @return result The ABI-encoded result
    function getResult(uint256 tocId) external view returns (bytes memory result);

    /// @notice Get the original proposed result (before any corrections)
    /// @dev Useful for UI audit trails
    /// @param tocId The TOC identifier
    /// @return result The original ABI-encoded result
    function getOriginalResult(uint256 tocId) external view returns (bytes memory result);

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

    /// @notice Get the next TOC ID that will be assigned
    /// @return The next TOC ID
    function nextTocId() external view returns (uint256);

    /// @notice Get the default dispute window duration
    /// @return Duration in seconds
    function defaultDisputeWindow() external view returns (uint256);

    // ============ Flexible Dispute Window View Functions ============

    /// @notice Check if a TOC is fully finalized (resolved and all dispute windows closed)
    /// @param tocId The TOC identifier
    /// @return True if fully finalized
    function isFullyFinalized(uint256 tocId) external view returns (bool);

    /// @notice Check if a TOC has been contested via post-resolution dispute
    /// @param tocId The TOC identifier
    /// @return True if contested
    function isContested(uint256 tocId) external view returns (bool);

    /// @notice Check if a TOC has a corrected result (post-resolution dispute was upheld)
    /// @param tocId The TOC identifier
    /// @return True if has corrected result
    function hasCorrectedResult(uint256 tocId) external view returns (bool);

    // ============ TruthKeeper View Functions ============

    /// @notice Check if an address is a whitelisted TruthKeeper
    /// @param tk Address to check
    /// @return True if whitelisted
    function isWhitelistedTruthKeeper(address tk) external view returns (bool);

    /// @notice Get escalation info for a TOC
    /// @param tocId The TOC identifier
    /// @return info The escalation information
    function getEscalationInfo(uint256 tocId) external view returns (EscalationInfo memory info);

    /// @notice Check if a bond is acceptable for escalation
    /// @param token Token address
    /// @param amount Amount
    /// @return True if acceptable
    function isAcceptableEscalationBond(address token, uint256 amount) external view returns (bool);

    // ============ Consumer Result Functions ============

    /// @notice Get result with full resolution context
    /// @param tocId The TOC identifier
    /// @return result The extensive result with context
    function getExtensiveResult(uint256 tocId) external view returns (ExtensiveResult memory result);

    /// @notice Get result only if fully finalized (reverts otherwise)
    /// @param tocId The TOC identifier
    /// @return result The extensive result with context
    function getExtensiveResultStrict(uint256 tocId) external view returns (ExtensiveResult memory result);
}
