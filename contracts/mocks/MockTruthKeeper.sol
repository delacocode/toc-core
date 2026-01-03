// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper} from "../TruthEngine/ITruthKeeper.sol";
import {TKApprovalResponse} from "../TruthEngine/TOCTypes.sol";

/// @title MockTruthKeeper
/// @notice Simple mock TruthKeeper for testing - always approves TOCs
contract MockTruthKeeper is ITruthKeeper {
    address public registry;

    constructor(address _registry) {
        registry = _registry;
    }

    function canAcceptToc(
        address /* resolver */,
        uint32 /* templateId */,
        address /* creator */,
        bytes calldata /* payload */,
        uint32 /* disputeWindow */,
        uint32 /* truthKeeperWindow */,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external pure returns (TKApprovalResponse) {
        return TKApprovalResponse.APPROVE;
    }

    function onTocAssigned(
        uint256 /* tocId */,
        address /* resolver */,
        uint32 /* templateId */,
        address /* creator */,
        bytes calldata /* payload */,
        uint32 /* disputeWindow */,
        uint32 /* truthKeeperWindow */,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external pure returns (TKApprovalResponse) {
        return TKApprovalResponse.APPROVE;
    }

    receive() external payable {}
}
