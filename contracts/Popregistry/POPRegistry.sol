// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./POPTypes.sol";
import "./IPOPRegistry.sol";
import "./IPopResolver.sol";

/// @title POPRegistry
/// @notice Central registry managing POP lifecycle, resolvers, and disputes
/// @dev Implementation of IPOPRegistry with dual resolver system (System vs Public)
contract POPRegistry is IPOPRegistry, ReentrancyGuard, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Default dispute window if resolver doesn't specify one
    uint256 public constant DEFAULT_DISPUTE_WINDOW_DURATION = 24 hours;

    // ============ State Variables ============

    // System resolver storage
    EnumerableSet.AddressSet private _systemResolvers;
    mapping(address => uint256) private _systemResolverToId;
    mapping(uint256 => address) private _systemIdToResolver;
    uint256 private _nextSystemResolverId;
    mapping(address => SystemResolverConfig) private _systemResolverConfigs;

    // Public resolver storage
    EnumerableSet.AddressSet private _publicResolvers;
    mapping(address => uint256) private _publicResolverToId;
    mapping(uint256 => address) private _publicIdToResolver;
    uint256 private _nextPublicResolverId;
    mapping(address => PublicResolverConfig) private _publicResolverConfigs;

    // Unified resolver type lookup
    mapping(address => ResolverType) private _resolverTypes;

    // POP storage
    mapping(uint256 => POP) private _pops;
    mapping(uint256 => DisputeInfo) private _disputes;
    mapping(uint256 => ResolutionInfo) private _resolutions;
    mapping(uint256 => bool) private _booleanResults;
    mapping(uint256 => int256) private _numericResults;
    mapping(uint256 => bytes) private _genericResults;
    uint256 private _nextPopId;

    // Bond configuration
    BondRequirement[] private _acceptableResolutionBonds;
    BondRequirement[] private _acceptableDisputeBonds;

    // Settings
    uint256 private _defaultDisputeWindow;

    // ============ Errors ============

    error ResolverNotApproved(address resolver);
    error ResolverAlreadyRegistered(address resolver);
    error ResolverNotRegistered(address resolver);
    error InvalidResolverId(uint256 resolverId);
    error InvalidTemplateId(uint32 templateId);
    error InvalidPopId(uint256 popId);
    error InvalidState(POPState current, POPState expected);
    error InvalidBond(address token, uint256 amount);
    error DisputeWindowNotPassed(uint256 deadline, uint256 current);
    error DisputeWindowPassed(uint256 deadline, uint256 current);
    error AlreadyDisputed(uint256 popId);
    error NotResolver(address caller, address expected);
    error TransferFailed();
    error InsufficientValue(uint256 sent, uint256 required);
    error InvalidResolverType(ResolverType resolverType);
    error ResolverIsDeprecated(address resolver);
    error CannotRestoreActiveResolver(address resolver);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        _defaultDisputeWindow = DEFAULT_DISPUTE_WINDOW_DURATION;
        _nextSystemResolverId = 1; // Start from 1, 0 means invalid
        _nextPublicResolverId = 1; // Start from 1, 0 means invalid
        _nextPopId = 1; // Start from 1, 0 means invalid
    }

    // ============ Modifiers ============

    modifier onlyResolver(uint256 popId) {
        POP storage pop = _pops[popId];
        if (msg.sender != pop.resolver) {
            revert NotResolver(msg.sender, pop.resolver);
        }
        _;
    }

    modifier validPopId(uint256 popId) {
        if (popId == 0 || popId >= _nextPopId) {
            revert InvalidPopId(popId);
        }
        _;
    }

    modifier inState(uint256 popId, POPState expected) {
        POPState current = _pops[popId].state;
        if (current != expected) {
            revert InvalidState(current, expected);
        }
        _;
    }

    // ============ Admin Functions ============

    /// @inheritdoc IPOPRegistry
    function registerResolver(ResolverType resolverType, address resolver) external onlyOwner {
        if (resolver == address(0)) {
            revert ResolverNotRegistered(resolver);
        }
        if (resolverType != ResolverType.SYSTEM && resolverType != ResolverType.PUBLIC) {
            revert InvalidResolverType(resolverType);
        }
        if (_resolverTypes[resolver] != ResolverType.NONE) {
            revert ResolverAlreadyRegistered(resolver);
        }

        _resolverTypes[resolver] = resolverType;
        uint256 resolverId;

        if (resolverType == ResolverType.SYSTEM) {
            _systemResolvers.add(resolver);
            resolverId = _nextSystemResolverId++;
            _systemResolverToId[resolver] = resolverId;
            _systemIdToResolver[resolverId] = resolver;
            _systemResolverConfigs[resolver] = SystemResolverConfig({
                disputeWindow: 0,
                isActive: true,
                registeredAt: block.timestamp,
                registeredBy: msg.sender
            });
        } else {
            _publicResolvers.add(resolver);
            resolverId = _nextPublicResolverId++;
            _publicResolverToId[resolver] = resolverId;
            _publicIdToResolver[resolverId] = resolver;
            _publicResolverConfigs[resolver] = PublicResolverConfig({
                disputeWindow: 0,
                isActive: true,
                registeredAt: block.timestamp,
                registeredBy: msg.sender
            });
        }

        emit ResolverRegistered(resolver, resolverType, resolverId);
    }

    /// @inheritdoc IPOPRegistry
    function deprecateResolver(ResolverType resolverType, address resolver) external onlyOwner {
        ResolverType currentType = _resolverTypes[resolver];
        if (currentType == ResolverType.NONE) {
            revert ResolverNotRegistered(resolver);
        }
        if (currentType == ResolverType.DEPRECATED) {
            revert ResolverIsDeprecated(resolver);
        }
        if (currentType != resolverType) {
            revert InvalidResolverType(resolverType);
        }

        // Set type to DEPRECATED but keep in sets for existing POPs
        _resolverTypes[resolver] = ResolverType.DEPRECATED;

        // Mark as inactive in config
        if (resolverType == ResolverType.SYSTEM) {
            _systemResolverConfigs[resolver].isActive = false;
        } else {
            _publicResolverConfigs[resolver].isActive = false;
        }

        emit ResolverDeprecated(resolver, resolverType);
    }

    /// @inheritdoc IPOPRegistry
    function restoreResolver(address resolver, ResolverType newType) external onlyOwner {
        if (newType != ResolverType.SYSTEM && newType != ResolverType.PUBLIC) {
            revert InvalidResolverType(newType);
        }
        ResolverType currentType = _resolverTypes[resolver];
        if (currentType != ResolverType.DEPRECATED) {
            revert CannotRestoreActiveResolver(resolver);
        }

        // Determine original type from which set contains the resolver
        bool wasSystem = _systemResolvers.contains(resolver);

        _resolverTypes[resolver] = newType;

        // Reactivate in appropriate config
        if (newType == ResolverType.SYSTEM) {
            if (!wasSystem) {
                // Moving from public to system
                _publicResolvers.remove(resolver);
                _systemResolvers.add(resolver);
                uint256 newId = _nextSystemResolverId++;
                _systemResolverToId[resolver] = newId;
                _systemIdToResolver[newId] = resolver;
                _systemResolverConfigs[resolver] = SystemResolverConfig({
                    disputeWindow: _publicResolverConfigs[resolver].disputeWindow,
                    isActive: true,
                    registeredAt: block.timestamp,
                    registeredBy: msg.sender
                });
            } else {
                _systemResolverConfigs[resolver].isActive = true;
            }
        } else {
            if (wasSystem) {
                // Moving from system to public
                _systemResolvers.remove(resolver);
                _publicResolvers.add(resolver);
                uint256 newId = _nextPublicResolverId++;
                _publicResolverToId[resolver] = newId;
                _publicIdToResolver[newId] = resolver;
                _publicResolverConfigs[resolver] = PublicResolverConfig({
                    disputeWindow: _systemResolverConfigs[resolver].disputeWindow,
                    isActive: true,
                    registeredAt: block.timestamp,
                    registeredBy: msg.sender
                });
            } else {
                _publicResolverConfigs[resolver].isActive = true;
            }
        }

        emit ResolverRestored(resolver, ResolverType.DEPRECATED, newType);
    }

    /// @inheritdoc IPOPRegistry
    function updateSystemResolverConfig(
        address resolver,
        SystemResolverConfig calldata config
    ) external onlyOwner {
        if (_resolverTypes[resolver] != ResolverType.SYSTEM) {
            revert InvalidResolverType(_resolverTypes[resolver]);
        }
        _systemResolverConfigs[resolver] = config;
        emit SystemResolverConfigUpdated(resolver, config);
    }

    /// @inheritdoc IPOPRegistry
    function updatePublicResolverConfig(
        address resolver,
        PublicResolverConfig calldata config
    ) external onlyOwner {
        if (_resolverTypes[resolver] != ResolverType.PUBLIC) {
            revert InvalidResolverType(_resolverTypes[resolver]);
        }
        _publicResolverConfigs[resolver] = config;
        emit PublicResolverConfigUpdated(resolver, config);
    }

    /// @inheritdoc IPOPRegistry
    function addAcceptableResolutionBond(
        address token,
        uint256 minAmount
    ) external onlyOwner {
        _acceptableResolutionBonds.push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
    }

    /// @inheritdoc IPOPRegistry
    function addAcceptableDisputeBond(
        address token,
        uint256 minAmount
    ) external onlyOwner {
        _acceptableDisputeBonds.push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
    }

    /// @inheritdoc IPOPRegistry
    function setDefaultDisputeWindow(uint256 duration) external onlyOwner {
        _defaultDisputeWindow = duration;
    }

    // ============ POP Lifecycle ============

    /// @inheritdoc IPOPRegistry
    function createPOPWithSystemResolver(
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (uint256 popId) {
        return _createPOP(ResolverType.SYSTEM, resolverId, templateId, payload);
    }

    /// @inheritdoc IPOPRegistry
    function createPOPWithPublicResolver(
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (uint256 popId) {
        return _createPOP(ResolverType.PUBLIC, resolverId, templateId, payload);
    }

    function _createPOP(
        ResolverType resolverType,
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload
    ) internal returns (uint256 popId) {
        address resolver;
        bool isActive;

        if (resolverType == ResolverType.SYSTEM) {
            resolver = _systemIdToResolver[resolverId];
            if (resolver == address(0)) {
                revert InvalidResolverId(resolverId);
            }
            isActive = _systemResolverConfigs[resolver].isActive;
        } else if (resolverType == ResolverType.PUBLIC) {
            resolver = _publicIdToResolver[resolverId];
            if (resolver == address(0)) {
                revert InvalidResolverId(resolverId);
            }
            isActive = _publicResolverConfigs[resolver].isActive;
        } else {
            revert InvalidResolverType(resolverType);
        }

        if (!isActive) {
            revert ResolverNotApproved(resolver);
        }

        // Check resolver isn't deprecated
        if (_resolverTypes[resolver] == ResolverType.DEPRECATED) {
            revert ResolverIsDeprecated(resolver);
        }

        // Validate template exists on resolver
        if (!IPopResolver(resolver).isValidTemplate(templateId)) {
            revert InvalidTemplateId(templateId);
        }

        // Get the answer type for this template
        AnswerType answerType = IPopResolver(resolver).getTemplateAnswerType(templateId);

        // Generate POP ID
        popId = _nextPopId++;

        // Call resolver to create POP
        POPState initialState = IPopResolver(resolver).onPopCreated(popId, templateId, payload);

        // Store POP
        _pops[popId] = POP({
            resolver: resolver,
            state: initialState,
            answerType: answerType,
            resolutionTime: 0,
            disputeDeadline: 0
        });

        emit POPCreated(popId, resolverType, resolverId, resolver, templateId, answerType, initialState);
    }

    /// @inheritdoc IPOPRegistry
    function resolvePOP(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) external payable nonReentrant validPopId(popId) inState(popId, POPState.ACTIVE) {
        // Validate bond
        if (!_isAcceptableResolutionBond(bondToken, bondAmount)) {
            revert InvalidBond(bondToken, bondAmount);
        }

        // Transfer bond in
        _transferBondIn(bondToken, bondAmount);

        POP storage pop = _pops[popId];

        // Call resolver to get typed outcome
        (bool boolResult, int256 numResult, bytes memory genResult) =
            IPopResolver(pop.resolver).resolvePop(popId, msg.sender, payload);

        // Store resolution info with typed outcome
        _resolutions[popId] = ResolutionInfo({
            proposer: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            proposedBooleanOutcome: boolResult,
            proposedNumericOutcome: numResult,
            proposedGenericOutcome: genResult
        });

        // Update POP state
        pop.state = POPState.RESOLVING;
        pop.resolutionTime = block.timestamp;
        pop.disputeDeadline = block.timestamp + _getDisputeWindow(pop.resolver);

        emit ResolutionBondDeposited(popId, msg.sender, bondToken, bondAmount);
        emit POPResolutionProposed(popId, msg.sender, pop.answerType, pop.disputeDeadline);
    }

    /// @inheritdoc IPOPRegistry
    function finalizePOP(uint256 popId) external nonReentrant validPopId(popId) inState(popId, POPState.RESOLVING) {
        POP storage pop = _pops[popId];

        // Check dispute window has passed
        if (block.timestamp < pop.disputeDeadline) {
            revert DisputeWindowNotPassed(pop.disputeDeadline, block.timestamp);
        }

        // Get resolution info
        ResolutionInfo storage resolution = _resolutions[popId];

        // Finalize the POP
        pop.state = POPState.RESOLVED;

        // Store the final result in the appropriate mapping
        if (pop.answerType == AnswerType.BOOLEAN) {
            _booleanResults[popId] = resolution.proposedBooleanOutcome;
        } else if (pop.answerType == AnswerType.NUMERIC) {
            _numericResults[popId] = resolution.proposedNumericOutcome;
        } else if (pop.answerType == AnswerType.GENERIC) {
            _genericResults[popId] = resolution.proposedGenericOutcome;
        }

        // Return resolution bond to proposer
        _transferBondOut(resolution.proposer, resolution.bondToken, resolution.bondAmount);

        emit ResolutionBondReturned(popId, resolution.proposer, resolution.bondToken, resolution.bondAmount);
        emit POPFinalized(popId, pop.answerType);
    }

    // ============ Dispute System ============

    /// @inheritdoc IPOPRegistry
    function dispute(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason
    ) external payable nonReentrant validPopId(popId) inState(popId, POPState.RESOLVING) {
        POP storage pop = _pops[popId];

        // Check we're still in dispute window
        if (block.timestamp >= pop.disputeDeadline) {
            revert DisputeWindowPassed(pop.disputeDeadline, block.timestamp);
        }

        // Check not already disputed
        if (_disputes[popId].disputer != address(0)) {
            revert AlreadyDisputed(popId);
        }

        // Validate bond
        if (!_isAcceptableDisputeBond(bondToken, bondAmount)) {
            revert InvalidBond(bondToken, bondAmount);
        }

        // Transfer bond in
        _transferBondIn(bondToken, bondAmount);

        // Store dispute info
        _disputes[popId] = DisputeInfo({
            disputer: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            reason: reason
        });

        // Update POP state
        pop.state = POPState.DISPUTED;

        emit DisputeBondDeposited(popId, msg.sender, bondToken, bondAmount);
        emit POPDisputed(popId, msg.sender, reason);
    }

    /// @inheritdoc IPOPRegistry
    function resolveDispute(
        uint256 popId,
        DisputeResolution resolution
    ) external onlyOwner nonReentrant validPopId(popId) inState(popId, POPState.DISPUTED) {
        POP storage pop = _pops[popId];
        DisputeInfo storage disputeInfo = _disputes[popId];
        ResolutionInfo storage resolutionInfo = _resolutions[popId];

        if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
            // Disputer was right - flip outcome (for boolean) or invalidate
            pop.state = POPState.RESOLVED;

            // For boolean, flip the outcome
            if (pop.answerType == AnswerType.BOOLEAN) {
                _booleanResults[popId] = !resolutionInfo.proposedBooleanOutcome;
            }
            // For numeric/generic, admin must provide correct answer via separate mechanism
            // For now, we don't set a result for disputed numeric/generic POPs

            // Slash resolution bond (stays in contract for admin to withdraw later)
            emit BondSlashed(popId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            // Return dispute bond to disputer
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(popId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            emit POPResolved(popId, pop.answerType);

        } else if (resolution == DisputeResolution.REJECT_DISPUTE) {
            // Original outcome stands - slash dispute bond, return resolution bond
            pop.state = POPState.RESOLVED;
            if (pop.answerType == AnswerType.BOOLEAN) {
                _booleanResults[popId] = resolutionInfo.proposedBooleanOutcome;
            } else if (pop.answerType == AnswerType.NUMERIC) {
                _numericResults[popId] = resolutionInfo.proposedNumericOutcome;
            } else if (pop.answerType == AnswerType.GENERIC) {
                _genericResults[popId] = resolutionInfo.proposedGenericOutcome;
            }

            // Slash dispute bond (stays in contract for admin to withdraw later)
            emit BondSlashed(popId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            // Return resolution bond to proposer
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(popId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            emit POPResolved(popId, pop.answerType);

        } else {
            // CANCEL_POP - entire POP invalid, return both bonds
            pop.state = POPState.CANCELLED;

            // Return resolution bond
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(popId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            // Return dispute bond
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(popId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            emit POPCancelled(popId, "Admin cancelled during dispute resolution");
        }

        emit DisputeResolved(popId, resolution, msg.sender);
    }

    // ============ Resolver Callbacks ============

    /// @inheritdoc IPOPRegistry
    function approvePOP(uint256 popId) external validPopId(popId) onlyResolver(popId) inState(popId, POPState.PENDING) {
        _pops[popId].state = POPState.ACTIVE;
        emit POPApproved(popId);
    }

    /// @inheritdoc IPOPRegistry
    function rejectPOP(uint256 popId, string calldata reason) external validPopId(popId) onlyResolver(popId) inState(popId, POPState.PENDING) {
        _pops[popId].state = POPState.REJECTED;
        emit POPRejected(popId, reason);
    }

    // ============ View Functions ============

    /// @inheritdoc IPOPRegistry
    function getPOP(uint256 popId) external view returns (POP memory) {
        return _pops[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getPOPInfo(uint256 popId) external view validPopId(popId) returns (POPInfo memory info) {
        POP storage pop = _pops[popId];
        ResolverType resolverType = _resolverTypes[pop.resolver];

        uint256 resolverId;
        uint256 disputeWindow;
        bool resolverIsActive;

        // Handle deprecated resolvers - check which set they belong to
        if (resolverType == ResolverType.SYSTEM ||
            (resolverType == ResolverType.DEPRECATED && _systemResolvers.contains(pop.resolver))) {
            resolverId = _systemResolverToId[pop.resolver];
            SystemResolverConfig storage config = _systemResolverConfigs[pop.resolver];
            disputeWindow = config.disputeWindow > 0 ? config.disputeWindow : _defaultDisputeWindow;
            resolverIsActive = config.isActive;
        } else {
            resolverId = _publicResolverToId[pop.resolver];
            PublicResolverConfig storage config = _publicResolverConfigs[pop.resolver];
            disputeWindow = config.disputeWindow > 0 ? config.disputeWindow : _defaultDisputeWindow;
            resolverIsActive = config.isActive;
        }

        info = POPInfo({
            resolver: pop.resolver,
            state: pop.state,
            answerType: pop.answerType,
            resolutionTime: pop.resolutionTime,
            disputeDeadline: pop.disputeDeadline,
            isResolved: pop.state == POPState.RESOLVED,
            booleanResult: _booleanResults[popId],
            numericResult: _numericResults[popId],
            genericResult: _genericResults[popId],
            resolverType: resolverType,
            resolverId: resolverId,
            disputeWindow: disputeWindow,
            resolverIsActive: resolverIsActive
        });
    }

    /// @inheritdoc IPOPRegistry
    function getPopDetails(
        uint256 popId
    ) external view validPopId(popId) returns (uint32 templateId, bytes memory creationPayload) {
        POP storage pop = _pops[popId];
        return IPopResolver(pop.resolver).getPopDetails(popId);
    }

    /// @inheritdoc IPOPRegistry
    function getPopQuestion(
        uint256 popId
    ) external view validPopId(popId) returns (string memory question) {
        POP storage pop = _pops[popId];
        return IPopResolver(pop.resolver).getPopQuestion(popId);
    }

    /// @inheritdoc IPOPRegistry
    function isApprovedResolver(ResolverType resolverType, address resolver) external view returns (bool) {
        if (resolverType == ResolverType.SYSTEM) {
            return _systemResolvers.contains(resolver) && _systemResolverConfigs[resolver].isActive;
        } else if (resolverType == ResolverType.PUBLIC) {
            return _publicResolvers.contains(resolver) && _publicResolverConfigs[resolver].isActive;
        }
        return false;
    }

    /// @inheritdoc IPOPRegistry
    function getResolverType(address resolver) external view returns (ResolverType) {
        return _resolverTypes[resolver];
    }

    /// @inheritdoc IPOPRegistry
    function getSystemResolverConfig(
        address resolver
    ) external view returns (SystemResolverConfig memory) {
        return _systemResolverConfigs[resolver];
    }

    /// @inheritdoc IPOPRegistry
    function getPublicResolverConfig(
        address resolver
    ) external view returns (PublicResolverConfig memory) {
        return _publicResolverConfigs[resolver];
    }

    /// @inheritdoc IPOPRegistry
    function getDisputeInfo(
        uint256 popId
    ) external view returns (DisputeInfo memory info) {
        return _disputes[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getResolutionInfo(
        uint256 popId
    ) external view returns (ResolutionInfo memory info) {
        return _resolutions[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getPOPResult(uint256 popId) external view validPopId(popId) returns (POPResult memory result) {
        POP storage pop = _pops[popId];
        result = POPResult({
            answerType: pop.answerType,
            isResolved: pop.state == POPState.RESOLVED,
            booleanResult: _booleanResults[popId],
            numericResult: _numericResults[popId],
            genericResult: _genericResults[popId]
        });
    }

    /// @inheritdoc IPOPRegistry
    function getBooleanResult(uint256 popId) external view validPopId(popId) returns (bool result) {
        return _booleanResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getNumericResult(uint256 popId) external view validPopId(popId) returns (int256 result) {
        return _numericResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getGenericResult(uint256 popId) external view validPopId(popId) returns (bytes memory result) {
        return _genericResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function isAcceptableResolutionBond(
        address token,
        uint256 amount
    ) external view returns (bool) {
        return _isAcceptableResolutionBond(token, amount);
    }

    /// @inheritdoc IPOPRegistry
    function isAcceptableDisputeBond(
        address token,
        uint256 amount
    ) external view returns (bool) {
        return _isAcceptableDisputeBond(token, amount);
    }

    /// @inheritdoc IPOPRegistry
    function nextPopId() external view returns (uint256) {
        return _nextPopId;
    }

    /// @inheritdoc IPOPRegistry
    function defaultDisputeWindow() external view returns (uint256) {
        return _defaultDisputeWindow;
    }

    /// @inheritdoc IPOPRegistry
    function getResolverAddress(ResolverType resolverType, uint256 resolverId) external view returns (address resolver) {
        if (resolverType == ResolverType.SYSTEM) {
            resolver = _systemIdToResolver[resolverId];
        } else if (resolverType == ResolverType.PUBLIC) {
            resolver = _publicIdToResolver[resolverId];
        } else {
            revert InvalidResolverType(resolverType);
        }
        if (resolver == address(0)) {
            revert InvalidResolverId(resolverId);
        }
    }

    /// @inheritdoc IPOPRegistry
    function getResolverId(ResolverType resolverType, address resolver) external view returns (uint256 resolverId) {
        if (resolverType == ResolverType.SYSTEM) {
            resolverId = _systemResolverToId[resolver];
        } else if (resolverType == ResolverType.PUBLIC) {
            resolverId = _publicResolverToId[resolver];
        } else {
            revert InvalidResolverType(resolverType);
        }
        if (resolverId == 0) {
            revert ResolverNotRegistered(resolver);
        }
    }

    /// @inheritdoc IPOPRegistry
    function getResolverCount(ResolverType resolverType) external view returns (uint256 count) {
        if (resolverType == ResolverType.SYSTEM) {
            return _systemResolvers.length();
        } else if (resolverType == ResolverType.PUBLIC) {
            return _publicResolvers.length();
        } else {
            revert InvalidResolverType(resolverType);
        }
    }

    // ============ Internal Functions ============

    /// @notice Check if a bond is acceptable for resolution
    function _isAcceptableResolutionBond(
        address token,
        uint256 amount
    ) internal view returns (bool) {
        for (uint256 i = 0; i < _acceptableResolutionBonds.length; i++) {
            if (
                _acceptableResolutionBonds[i].token == token &&
                amount >= _acceptableResolutionBonds[i].minAmount
            ) {
                return true;
            }
        }
        return false;
    }

    /// @notice Check if a bond is acceptable for dispute
    function _isAcceptableDisputeBond(
        address token,
        uint256 amount
    ) internal view returns (bool) {
        for (uint256 i = 0; i < _acceptableDisputeBonds.length; i++) {
            if (
                _acceptableDisputeBonds[i].token == token &&
                amount >= _acceptableDisputeBonds[i].minAmount
            ) {
                return true;
            }
        }
        return false;
    }

    /// @notice Transfer bond into the contract
    function _transferBondIn(address token, uint256 amount) internal {
        if (token == address(0)) {
            // Native token
            if (msg.value < amount) {
                revert InsufficientValue(msg.value, amount);
            }
        } else {
            // ERC20 token
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /// @notice Transfer bond out of the contract
    function _transferBondOut(address to, address token, uint256 amount) internal {
        if (token == address(0)) {
            // Native token
            (bool success, ) = to.call{value: amount}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            // ERC20 token
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Get the dispute window for a resolver
    function _getDisputeWindow(address resolver) internal view returns (uint256) {
        ResolverType resolverType = _resolverTypes[resolver];
        uint256 window;

        if (resolverType == ResolverType.SYSTEM ||
            (resolverType == ResolverType.DEPRECATED && _systemResolvers.contains(resolver))) {
            window = _systemResolverConfigs[resolver].disputeWindow;
        } else {
            window = _publicResolverConfigs[resolver].disputeWindow;
        }

        return window > 0 ? window : _defaultDisputeWindow;
    }
}
