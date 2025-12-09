// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper} from "../Popregistry/ITruthKeeper.sol";
import {TKApprovalResponse} from "../Popregistry/POPTypes.sol";

/// @title MockTruthKeeper
/// @notice Mock TruthKeeper for testing the POPRegistry
/// @dev Simple implementation that approves all POPs by default
contract MockTruthKeeper is ITruthKeeper {
    address public registry;

    // Configurable behavior
    TKApprovalResponse public defaultResponse = TKApprovalResponse.APPROVE;

    // Per-resolver response overrides
    mapping(address => TKApprovalResponse) public resolverResponses;
    mapping(address => bool) public hasResolverOverride;

    // Per-creator response overrides
    mapping(address => TKApprovalResponse) public creatorResponses;
    mapping(address => bool) public hasCreatorOverride;

    // Tracking
    uint256 public totalPopsAssigned;
    mapping(uint256 => bool) public assignedPops;

    error OnlyRegistry();

    constructor(address _registry) {
        registry = _registry;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }

    // ============ Configuration ============

    function setRegistry(address _registry) external {
        registry = _registry;
    }

    function setDefaultResponse(TKApprovalResponse response) external {
        defaultResponse = response;
    }

    function setResolverResponse(address resolver, TKApprovalResponse response) external {
        resolverResponses[resolver] = response;
        hasResolverOverride[resolver] = true;
    }

    function clearResolverOverride(address resolver) external {
        hasResolverOverride[resolver] = false;
    }

    function setCreatorResponse(address creator, TKApprovalResponse response) external {
        creatorResponses[creator] = response;
        hasCreatorOverride[creator] = true;
    }

    function clearCreatorOverride(address creator) external {
        hasCreatorOverride[creator] = false;
    }

    // ============ ITruthKeeper Implementation ============

    /// @inheritdoc ITruthKeeper
    function canAcceptPop(
        address resolver,
        uint32 /* templateId */,
        address creator,
        bytes calldata /* payload */,
        uint32 /* disputeWindow */,
        uint32 /* truthKeeperWindow */,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external view returns (TKApprovalResponse) {
        return _evaluate(resolver, creator);
    }

    /// @inheritdoc ITruthKeeper
    function onPopAssigned(
        uint256 popId,
        address resolver,
        uint32 /* templateId */,
        address creator,
        bytes calldata /* payload */,
        uint32 /* disputeWindow */,
        uint32 /* truthKeeperWindow */,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external onlyRegistry returns (TKApprovalResponse) {
        assignedPops[popId] = true;
        totalPopsAssigned++;
        return _evaluate(resolver, creator);
    }

    function _evaluate(address resolver, address creator) internal view returns (TKApprovalResponse) {
        // Check resolver override first
        if (hasResolverOverride[resolver]) {
            return resolverResponses[resolver];
        }

        // Check creator override
        if (hasCreatorOverride[creator]) {
            return creatorResponses[creator];
        }

        // Return default
        return defaultResponse;
    }
}
