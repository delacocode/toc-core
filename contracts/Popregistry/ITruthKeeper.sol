// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {TKApprovalResponse} from "./POPTypes.sol";

/// @title ITruthKeeper
/// @notice Interface for TruthKeeper contracts that validate and approve POPs
/// @dev TruthKeepers must be contracts implementing this interface. EOAs are not supported.
interface ITruthKeeper {
    /// @notice Pre-check if TK would accept a POP with these parameters
    /// @dev View function for gas-efficient dry-runs and UI pre-validation.
    ///      Called before popId is assigned, so no popId parameter.
    /// @param resolver The resolver contract address
    /// @param templateId The template ID within the resolver
    /// @param creator The address creating the POP
    /// @param payload The resolver-specific payload (raw bytes)
    /// @param disputeWindow Time window for disputing resolution
    /// @param truthKeeperWindow Time window for TK to decide disputes
    /// @param escalationWindow Time window to challenge TK decision
    /// @param postResolutionWindow Time window for post-resolution disputes
    /// @return response The approval decision TK would make
    function canAcceptPop(
        address resolver,
        uint32 templateId,
        address creator,
        bytes calldata payload,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 escalationWindow,
        uint32 postResolutionWindow
    ) external view returns (TKApprovalResponse response);

    /// @notice Called when a POP is created with this TK assigned
    /// @dev Can update internal state (track POPs, counters, etc.).
    ///      Must verify msg.sender is the trusted registry.
    /// @param popId The newly created POP ID
    /// @param resolver The resolver contract address
    /// @param templateId The template ID within the resolver
    /// @param creator The address creating the POP
    /// @param payload The resolver-specific payload (raw bytes)
    /// @param disputeWindow Time window for disputing resolution
    /// @param truthKeeperWindow Time window for TK to decide disputes
    /// @param escalationWindow Time window to challenge TK decision
    /// @param postResolutionWindow Time window for post-resolution disputes
    /// @return response The approval decision
    function onPopAssigned(
        uint256 popId,
        address resolver,
        uint32 templateId,
        address creator,
        bytes calldata payload,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 escalationWindow,
        uint32 postResolutionWindow
    ) external returns (TKApprovalResponse response);
}
