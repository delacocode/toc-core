// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper} from "./TOCRegistry/ITruthKeeper.sol";
import {TKApprovalResponse} from "./TOCRegistry/TOCTypes.sol";

/// @title SimpleTruthKeeper
/// @notice Minimal TruthKeeper for initial launch with resolver allowlist and time window validation
/// @dev Returns APPROVE only when resolver is allowed AND time windows meet minimums
contract SimpleTruthKeeper is ITruthKeeper {
    // ============ State Variables ============

    address public owner;
    address public registry;

    // Global default minimums
    uint32 public defaultMinDisputeWindow;
    uint32 public defaultMinTruthKeeperWindow;

    // Resolver allowlist
    mapping(address => bool) public allowedResolvers;

    // Per-resolver time window overrides (0 = use global default)
    mapping(address => uint32) public resolverMinDisputeWindow;
    mapping(address => uint32) public resolverMinTruthKeeperWindow;

    // ============ Errors ============

    error OnlyOwner();
    error OnlyRegistry();
    error ZeroAddress();

    // ============ Events ============

    event ResolverAllowedChanged(address indexed resolver, bool allowed);
    event DefaultMinWindowsChanged(uint32 disputeWindow, uint32 tkWindow);
    event ResolverMinWindowsChanged(address indexed resolver, uint32 disputeWindow, uint32 tkWindow);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

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

    constructor(
        address _registry,
        address _owner,
        uint32 _defaultMinDisputeWindow,
        uint32 _defaultMinTruthKeeperWindow
    ) {
        if (_registry == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        registry = _registry;
        owner = _owner;
        defaultMinDisputeWindow = _defaultMinDisputeWindow;
        defaultMinTruthKeeperWindow = _defaultMinTruthKeeperWindow;
    }

    // Placeholder for ITruthKeeper - will implement in next task
    function canAcceptToc(
        address,
        uint32,
        address,
        bytes calldata,
        uint32,
        uint32,
        uint32,
        uint32
    ) external view returns (TKApprovalResponse) {
        return TKApprovalResponse.REJECT_SOFT;
    }

    function onTocAssigned(
        uint256,
        address,
        uint32,
        address,
        bytes calldata,
        uint32,
        uint32,
        uint32,
        uint32
    ) external onlyRegistry returns (TKApprovalResponse) {
        return TKApprovalResponse.REJECT_SOFT;
    }

    receive() external payable {}
}
