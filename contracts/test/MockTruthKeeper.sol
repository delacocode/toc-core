// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper} from "../TOCRegistry/ITruthKeeper.sol";
import {ITOCRegistry} from "../TOCRegistry/ITOCRegistry.sol";
import {TKApprovalResponse, DisputeResolution} from "../TOCRegistry/TOCTypes.sol";

/// @title MockTruthKeeper
/// @notice Mock TruthKeeper for testing the TOCRegistry
/// @dev Simple implementation that approves all TOCs by default
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
    uint256 public totalTocsAssigned;
    mapping(uint256 => bool) public assignedTocs;

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
    function canAcceptToc(
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
    function onTocAssigned(
        uint256 tocId,
        address resolver,
        uint32 /* templateId */,
        address creator,
        bytes calldata /* payload */,
        uint32 /* disputeWindow */,
        uint32 /* truthKeeperWindow */,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external onlyRegistry returns (TKApprovalResponse) {
        assignedTocs[tocId] = true;
        totalTocsAssigned++;
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

    // ============ Helper Functions for Testing ============

    function resolveDispute(
        address registryAddr,
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external {
        ITOCRegistry(registryAddr).resolveTruthKeeperDispute(tocId, resolution, correctedResult);
    }

    function withdrawFees(address registryAddr, address token) external {
        ITOCRegistry(registryAddr).withdrawTKFees(token);
    }

    receive() external payable {}
}
