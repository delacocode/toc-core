// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "./POPTypes.sol";

/// @title IPOPRegistry
/// @notice Interface for the POP Registry contract
/// @dev Central contract managing POP lifecycle, resolvers, and disputes
interface IPOPRegistry {
    // ============ Events ============

    // Resolver management
    event ResolverRegistered(address indexed resolver, ResolverType indexed resolverType, uint256 resolverId);
    event ResolverDeprecated(address indexed resolver, ResolverType indexed resolverType);
    event ResolverRestored(address indexed resolver, ResolverType indexed fromType, ResolverType newType);
    event SystemResolverConfigUpdated(address indexed resolver, SystemResolverConfig config);
    event PublicResolverConfigUpdated(address indexed resolver, PublicResolverConfig config);

    // POP lifecycle
    event POPCreated(
        uint256 indexed popId,
        ResolverType indexed resolverType,
        uint256 indexed resolverId,
        address resolver,
        uint32 templateId,
        AnswerType answerType,
        POPState initialState
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
    event DisputeResolved(
        uint256 indexed popId,
        DisputeResolution resolution,
        address indexed admin
    );
    event POPCancelled(uint256 indexed popId, string reason);

    // Bonds
    event ResolutionBondDeposited(uint256 indexed popId, address indexed proposer, address token, uint256 amount);
    event ResolutionBondReturned(uint256 indexed popId, address indexed to, address token, uint256 amount);
    event DisputeBondDeposited(uint256 indexed popId, address indexed disputer, address token, uint256 amount);
    event DisputeBondReturned(uint256 indexed popId, address indexed to, address token, uint256 amount);
    event BondSlashed(uint256 indexed popId, address indexed from, address token, uint256 amount);

    // ============ Admin Functions ============

    /// @notice Register a new resolver
    /// @param resolverType Type of resolver (SYSTEM or PUBLIC)
    /// @param resolver Address of the resolver contract
    function registerResolver(ResolverType resolverType, address resolver) external;

    /// @notice Deprecate a resolver (cannot create new POPs, existing ones still work)
    /// @param resolverType Type of resolver being deprecated
    /// @param resolver Address of the resolver to deprecate
    function deprecateResolver(ResolverType resolverType, address resolver) external;

    /// @notice Restore a deprecated resolver
    /// @param resolver Address of the resolver to restore
    /// @param newType Type to restore as (can change from original)
    function restoreResolver(address resolver, ResolverType newType) external;

    /// @notice Update system resolver configuration
    /// @param resolver Address of the resolver
    /// @param config New configuration
    function updateSystemResolverConfig(address resolver, SystemResolverConfig calldata config) external;

    /// @notice Update public resolver configuration
    /// @param resolver Address of the resolver
    /// @param config New configuration
    function updatePublicResolverConfig(address resolver, PublicResolverConfig calldata config) external;

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

    // ============ POP Lifecycle ============

    /// @notice Create a new POP using a system resolver
    /// @param resolverId ID of the system resolver to use
    /// @param templateId Template ID within the resolver
    /// @param payload Creation parameters encoded for the template
    /// @return popId The unique identifier for the new POP
    function createPOPWithSystemResolver(
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (uint256 popId);

    /// @notice Create a new POP using a public resolver
    /// @param resolverId ID of the public resolver to use
    /// @param templateId Template ID within the resolver
    /// @param payload Creation parameters encoded for the template
    /// @return popId The unique identifier for the new POP
    function createPOPWithPublicResolver(
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload
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

    /// @notice Dispute a proposed resolution
    /// @param popId The POP to dispute
    /// @param bondToken Token to use for dispute bond
    /// @param bondAmount Amount of bond to post
    /// @param reason Reason for the dispute
    function dispute(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason
    ) external payable;

    /// @notice Admin resolves a dispute
    /// @param popId The disputed POP
    /// @param resolution How to resolve the dispute
    function resolveDispute(uint256 popId, DisputeResolution resolution) external;

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

    /// @notice Check if a resolver is approved
    /// @param resolverType Type of resolver to check
    /// @param resolver Address to check
    /// @return True if approved and active
    function isApprovedResolver(ResolverType resolverType, address resolver) external view returns (bool);

    /// @notice Get resolver type for an address
    /// @param resolver Address to check
    /// @return The resolver type (NONE if not registered)
    function getResolverType(address resolver) external view returns (ResolverType);

    /// @notice Get system resolver configuration
    /// @param resolver Address of resolver
    /// @return config The resolver configuration
    function getSystemResolverConfig(address resolver) external view returns (SystemResolverConfig memory config);

    /// @notice Get public resolver configuration
    /// @param resolver Address of resolver
    /// @return config The resolver configuration
    function getPublicResolverConfig(address resolver) external view returns (PublicResolverConfig memory config);

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

    /// @notice Get resolver address by type and ID
    /// @param resolverType The resolver type
    /// @param resolverId The resolver ID
    /// @return resolver The resolver address
    function getResolverAddress(ResolverType resolverType, uint256 resolverId) external view returns (address resolver);

    /// @notice Get resolver ID by type and address
    /// @param resolverType The resolver type
    /// @param resolver The resolver address
    /// @return resolverId The resolver ID (reverts if not registered)
    function getResolverId(ResolverType resolverType, address resolver) external view returns (uint256 resolverId);

    /// @notice Get total number of registered resolvers of a type
    /// @param resolverType The resolver type
    /// @return count Number of resolvers
    function getResolverCount(ResolverType resolverType) external view returns (uint256 count);
}
