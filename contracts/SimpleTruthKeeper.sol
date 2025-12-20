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

    // ============ ITruthKeeper Implementation ============

    /// @inheritdoc ITruthKeeper
    function canAcceptToc(
        address resolver,
        uint32 /* templateId */,
        address /* creator */,
        bytes calldata /* payload */,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external view returns (TKApprovalResponse) {
        return _evaluate(resolver, disputeWindow, truthKeeperWindow);
    }

    /// @inheritdoc ITruthKeeper
    function onTocAssigned(
        uint256 /* tocId */,
        address resolver,
        uint32 /* templateId */,
        address /* creator */,
        bytes calldata /* payload */,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external onlyRegistry returns (TKApprovalResponse) {
        return _evaluate(resolver, disputeWindow, truthKeeperWindow);
    }

    // ============ Internal ============

    /// @notice Evaluate if a TOC should be approved
    /// @dev Returns APPROVE only if resolver is allowed AND time windows meet minimums
    function _evaluate(
        address resolver,
        uint32 disputeWindow,
        uint32 truthKeeperWindow
    ) internal view returns (TKApprovalResponse) {
        // Check resolver allowlist
        if (!allowedResolvers[resolver]) {
            return TKApprovalResponse.REJECT_SOFT;
        }

        // Get effective minimums (per-resolver override or global default)
        (uint32 minDispute, uint32 minTk) = getEffectiveMinWindows(resolver);

        // Check time windows
        if (disputeWindow < minDispute) {
            return TKApprovalResponse.REJECT_SOFT;
        }
        if (truthKeeperWindow < minTk) {
            return TKApprovalResponse.REJECT_SOFT;
        }

        return TKApprovalResponse.APPROVE;
    }

    // ============ View Helpers ============

    /// @notice Get effective minimum windows for a resolver
    /// @param resolver The resolver address
    /// @return minDisputeWindow The effective minimum dispute window
    /// @return minTkWindow The effective minimum TK window
    function getEffectiveMinWindows(address resolver)
        public
        view
        returns (uint32 minDisputeWindow, uint32 minTkWindow)
    {
        minDisputeWindow = resolverMinDisputeWindow[resolver];
        if (minDisputeWindow == 0) {
            minDisputeWindow = defaultMinDisputeWindow;
        }

        minTkWindow = resolverMinTruthKeeperWindow[resolver];
        if (minTkWindow == 0) {
            minTkWindow = defaultMinTruthKeeperWindow;
        }
    }

    /// @notice Check if a resolver is allowed
    /// @param resolver The resolver address
    /// @return allowed Whether the resolver is on the allowlist
    function isResolverAllowed(address resolver) external view returns (bool allowed) {
        return allowedResolvers[resolver];
    }

    // ============ Owner Functions ============

    /// @notice Add or remove a resolver from the allowlist
    /// @param resolver The resolver address
    /// @param allowed Whether to allow the resolver
    function setResolverAllowed(address resolver, bool allowed) external onlyOwner {
        allowedResolvers[resolver] = allowed;
        emit ResolverAllowedChanged(resolver, allowed);
    }

    /// @notice Set per-resolver minimum time windows
    /// @dev Set to 0 to use global defaults
    /// @param resolver The resolver address
    /// @param disputeWindow Minimum dispute window (0 = use default)
    /// @param tkWindow Minimum TK window (0 = use default)
    function setResolverMinWindows(
        address resolver,
        uint32 disputeWindow,
        uint32 tkWindow
    ) external onlyOwner {
        resolverMinDisputeWindow[resolver] = disputeWindow;
        resolverMinTruthKeeperWindow[resolver] = tkWindow;
        emit ResolverMinWindowsChanged(resolver, disputeWindow, tkWindow);
    }

    /// @notice Set global default minimum windows
    /// @param disputeWindow Default minimum dispute window
    /// @param tkWindow Default minimum TK window
    function setDefaultMinWindows(uint32 disputeWindow, uint32 tkWindow) external onlyOwner {
        defaultMinDisputeWindow = disputeWindow;
        defaultMinTruthKeeperWindow = tkWindow;
        emit DefaultMinWindowsChanged(disputeWindow, tkWindow);
    }

    /// @notice Batch add or remove resolvers from the allowlist
    /// @param resolvers Array of resolver addresses
    /// @param allowed Whether to allow the resolvers
    function setResolversAllowed(address[] calldata resolvers, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < resolvers.length; i++) {
            allowedResolvers[resolvers[i]] = allowed;
            emit ResolverAllowedChanged(resolvers[i], allowed);
        }
    }

    /// @notice Transfer ownership to a new address
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Update registry address
    /// @param newRegistry The new registry address
    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        address oldRegistry = registry;
        registry = newRegistry;
        emit RegistryUpdated(oldRegistry, newRegistry);
    }

    receive() external payable {}
}
