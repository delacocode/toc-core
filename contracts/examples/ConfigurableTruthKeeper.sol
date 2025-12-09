// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper} from "../Popregistry/ITruthKeeper.sol";
import {TKApprovalResponse} from "../Popregistry/POPTypes.sol";

/// @title ConfigurableTruthKeeper
/// @notice Example TruthKeeper contract that filters POPs based on configurable criteria
/// @dev Reference implementation showing how TK contracts can implement approval logic
contract ConfigurableTruthKeeper is ITruthKeeper {
    address public owner;
    address public registry;

    // Minimum time windows required
    uint32 public minDisputeWindow;
    uint32 public minTruthKeeperWindow;

    // Resolver filtering
    mapping(address => bool) public allowedResolvers;
    mapping(address => bool) public blockedResolvers;
    bool public useResolverAllowlist;

    // Creator filtering
    mapping(address => bool) public allowedCreators;
    mapping(address => bool) public blockedCreators;
    bool public useCreatorAllowlist;

    // Template filtering (resolver => templateId => blocked)
    mapping(address => mapping(uint32 => bool)) public blockedTemplates;

    // ============ Errors ============

    error OnlyRegistry();
    error OnlyOwner();

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }

    // ============ Constructor ============

    constructor(address _registry, address _owner) {
        registry = _registry;
        owner = _owner;
        minDisputeWindow = 1 hours;
        minTruthKeeperWindow = 4 hours;
    }

    // ============ ITruthKeeper Implementation ============

    /// @inheritdoc ITruthKeeper
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

    /// @inheritdoc ITruthKeeper
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
        // Could track popId internally here if needed for state management
        return _evaluate(resolver, templateId, creator, disputeWindow, truthKeeperWindow);
    }

    /// @notice Internal evaluation logic shared by canAcceptPop and onPopAssigned
    function _evaluate(
        address resolver,
        uint32 templateId,
        address creator,
        uint32 disputeWindow,
        uint32 truthKeeperWindow
    ) internal view returns (TKApprovalResponse) {
        // Hard reject: blocked resolver, creator, or template
        if (blockedResolvers[resolver]) return TKApprovalResponse.REJECT_HARD;
        if (blockedCreators[creator]) return TKApprovalResponse.REJECT_HARD;
        if (blockedTemplates[resolver][templateId]) return TKApprovalResponse.REJECT_HARD;

        // Hard reject: time windows too short for safe operation
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

    /// @notice Set minimum required time windows
    /// @param _disputeWindow Minimum dispute window in seconds
    /// @param _tkWindow Minimum TruthKeeper window in seconds
    function setMinWindows(uint32 _disputeWindow, uint32 _tkWindow) external onlyOwner {
        minDisputeWindow = _disputeWindow;
        minTruthKeeperWindow = _tkWindow;
    }

    /// @notice Enable/disable resolver allowlist mode
    /// @param enabled If true, only allowed resolvers are approved
    function setResolverAllowlist(bool enabled) external onlyOwner {
        useResolverAllowlist = enabled;
    }

    /// @notice Enable/disable creator allowlist mode
    /// @param enabled If true, only allowed creators are approved
    function setCreatorAllowlist(bool enabled) external onlyOwner {
        useCreatorAllowlist = enabled;
    }

    /// @notice Add/remove resolver from allowlist
    /// @param resolver Resolver address
    /// @param allowed Whether to allow
    function setResolverAllowed(address resolver, bool allowed) external onlyOwner {
        allowedResolvers[resolver] = allowed;
    }

    /// @notice Add/remove resolver from blocklist
    /// @param resolver Resolver address
    /// @param blocked Whether to block
    function setResolverBlocked(address resolver, bool blocked) external onlyOwner {
        blockedResolvers[resolver] = blocked;
    }

    /// @notice Add/remove creator from allowlist
    /// @param creator Creator address
    /// @param allowed Whether to allow
    function setCreatorAllowed(address creator, bool allowed) external onlyOwner {
        allowedCreators[creator] = allowed;
    }

    /// @notice Add/remove creator from blocklist
    /// @param creator Creator address
    /// @param blocked Whether to block
    function setCreatorBlocked(address creator, bool blocked) external onlyOwner {
        blockedCreators[creator] = blocked;
    }

    /// @notice Block/unblock a specific template on a resolver
    /// @param resolver Resolver address
    /// @param templateId Template to block
    /// @param blocked Whether to block
    function setTemplateBlocked(address resolver, uint32 templateId, bool blocked) external onlyOwner {
        blockedTemplates[resolver][templateId] = blocked;
    }

    /// @notice Transfer ownership
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @notice Update registry address (in case of migration)
    /// @param newRegistry New registry address
    function setRegistry(address newRegistry) external onlyOwner {
        registry = newRegistry;
    }
}
