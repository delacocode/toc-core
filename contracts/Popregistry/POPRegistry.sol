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

    // Corrected results storage (for post-resolution disputes)
    mapping(uint256 => bool) private _correctedBooleanResults;
    mapping(uint256 => int256) private _correctedNumericResults;
    mapping(uint256 => bytes) private _correctedGenericResults;
    mapping(uint256 => bool) private _hasCorrectedResult;

    // Bond configuration
    BondRequirement[] private _acceptableResolutionBonds;
    BondRequirement[] private _acceptableDisputeBonds;
    BondRequirement[] private _acceptableEscalationBonds;

    // Settings
    uint256 private _defaultDisputeWindow;

    // TruthKeeper registry
    EnumerableSet.AddressSet private _whitelistedTruthKeepers;
    EnumerableSet.AddressSet private _whitelistedResolvers;
    mapping(address => EnumerableSet.AddressSet) private _tkGuaranteedResolvers;

    // Escalation info storage
    mapping(uint256 => EscalationInfo) private _escalations;

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
    error NoCorrectedAnswerProvided(uint256 popId);
    error DisputeAlreadyResolved(uint256 popId);
    error NoDisputeExists(uint256 popId);
    error CannotDisputeInCurrentState(POPState currentState);
    error NotTruthKeeper(address caller, address expected);
    error TruthKeeperNotWhitelisted(address tk);
    error TruthKeeperAlreadyWhitelisted(address tk);
    error ResolverNotWhitelistedForSystem(address resolver);
    error TruthKeeperWindowNotPassed(uint256 deadline, uint256 current);
    error EscalationWindowNotPassed(uint256 deadline, uint256 current);
    error EscalationWindowPassed(uint256 deadline, uint256 current);
    error NotInDisputedRound1State(POPState currentState);
    error NotInDisputedRound2State(POPState currentState);
    error TruthKeeperAlreadyDecided(uint256 popId);
    error TruthKeeperNotYetDecided(uint256 popId);
    error AlreadyEscalated(uint256 popId);
    error InvalidTruthKeeper(address tk);

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

    modifier onlyTruthKeeper(uint256 popId) {
        POP storage pop = _pops[popId];
        if (msg.sender != pop.truthKeeper) {
            revert NotTruthKeeper(msg.sender, pop.truthKeeper);
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

    /// @inheritdoc IPOPRegistry
    function addWhitelistedTruthKeeper(address tk) external onlyOwner {
        if (tk == address(0)) revert InvalidTruthKeeper(tk);
        if (_whitelistedTruthKeepers.contains(tk)) revert TruthKeeperAlreadyWhitelisted(tk);
        _whitelistedTruthKeepers.add(tk);
        emit TruthKeeperWhitelisted(tk);
    }

    /// @inheritdoc IPOPRegistry
    function removeWhitelistedTruthKeeper(address tk) external onlyOwner {
        if (!_whitelistedTruthKeepers.contains(tk)) revert TruthKeeperNotWhitelisted(tk);
        _whitelistedTruthKeepers.remove(tk);
        emit TruthKeeperRemovedFromWhitelist(tk);
    }

    /// @inheritdoc IPOPRegistry
    function addWhitelistedResolver(address resolver) external onlyOwner {
        if (resolver == address(0)) revert ResolverNotRegistered(resolver);
        _whitelistedResolvers.add(resolver);
        emit ResolverAddedToWhitelist(resolver);
    }

    /// @inheritdoc IPOPRegistry
    function removeWhitelistedResolver(address resolver) external onlyOwner {
        _whitelistedResolvers.remove(resolver);
        emit ResolverRemovedFromWhitelist(resolver);
    }

    /// @inheritdoc IPOPRegistry
    function addAcceptableEscalationBond(address token, uint256 minAmount) external onlyOwner {
        _acceptableEscalationBonds.push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
    }

    // ============ TruthKeeper Functions ============

    /// @inheritdoc IPOPRegistry
    function addGuaranteedResolver(address resolver) external {
        _tkGuaranteedResolvers[msg.sender].add(resolver);
        emit TruthKeeperGuaranteeAdded(msg.sender, resolver);
    }

    /// @inheritdoc IPOPRegistry
    function removeGuaranteedResolver(address resolver) external {
        _tkGuaranteedResolvers[msg.sender].remove(resolver);
        emit TruthKeeperGuaranteeRemoved(msg.sender, resolver);
    }

    /// @inheritdoc IPOPRegistry
    function resolveTruthKeeperDispute(
        uint256 popId,
        DisputeResolution resolution,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult
    ) external nonReentrant validPopId(popId) onlyTruthKeeper(popId) {
        POP storage pop = _pops[popId];

        if (pop.state != POPState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(pop.state);
        }

        DisputeInfo storage disputeInfo = _disputes[popId];

        if (disputeInfo.tkDecidedAt != 0) {
            revert TruthKeeperAlreadyDecided(popId);
        }

        // Record TK decision
        disputeInfo.tkDecision = resolution;
        disputeInfo.tkDecidedAt = block.timestamp;

        // Set escalation deadline
        pop.escalationDeadline = block.timestamp + pop.escalationWindow;

        // Handle TOO_EARLY specially - immediately return to ACTIVE
        if (resolution == DisputeResolution.TOO_EARLY) {
            _handleTooEarlyResolution(popId, pop, disputeInfo);
        }
        // Other resolutions wait for escalation window

        emit TruthKeeperDisputeResolved(popId, msg.sender, resolution);
    }

    // ============ POP Lifecycle ============

    /// @inheritdoc IPOPRegistry
    function createPOPWithSystemResolver(
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
    ) external returns (uint256 popId) {
        return _createPOP(ResolverType.SYSTEM, resolverId, templateId, payload, disputeWindow, truthKeeperWindow, escalationWindow, postResolutionWindow, truthKeeper);
    }

    /// @inheritdoc IPOPRegistry
    function createPOPWithPublicResolver(
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
    ) external returns (uint256 popId) {
        return _createPOP(ResolverType.PUBLIC, resolverId, templateId, payload, disputeWindow, truthKeeperWindow, escalationWindow, postResolutionWindow, truthKeeper);
    }

    function _createPOP(
        ResolverType resolverType,
        uint256 resolverId,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
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

        // Calculate accountability tier (snapshot at creation)
        AccountabilityTier tier = _calculateAccountabilityTier(resolver, truthKeeper);

        // Generate POP ID
        popId = _nextPopId++;

        // Call resolver to create POP
        POPState initialState = IPopResolver(resolver).onPopCreated(popId, templateId, payload);

        // Store POP with user-specified dispute windows
        _pops[popId] = POP({
            resolver: resolver,
            state: initialState,
            answerType: answerType,
            resolutionTime: 0,
            disputeWindow: disputeWindow,
            truthKeeperWindow: truthKeeperWindow,
            escalationWindow: escalationWindow,
            postResolutionWindow: postResolutionWindow,
            disputeDeadline: 0,
            truthKeeperDeadline: 0,
            escalationDeadline: 0,
            postDisputeDeadline: 0,
            truthKeeper: truthKeeper,
            tierAtCreation: tier
        });

        emit POPCreated(popId, resolverType, resolverId, resolver, templateId, answerType, initialState, truthKeeper, tier);
    }

    /// @inheritdoc IPOPRegistry
    function resolvePOP(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) external payable nonReentrant validPopId(popId) inState(popId, POPState.ACTIVE) {
        POP storage pop = _pops[popId];

        // Bond is required only if any dispute window > 0
        bool requiresBond = pop.disputeWindow > 0 || pop.postResolutionWindow > 0;
        if (requiresBond) {
            if (!_isAcceptableResolutionBond(bondToken, bondAmount)) {
                revert InvalidBond(bondToken, bondAmount);
            }
            _transferBondIn(bondToken, bondAmount);
        }

        // Call resolver to get typed outcome and store resolution
        _storeResolutionInfo(popId, pop.resolver, bondToken, bondAmount, payload);

        pop.resolutionTime = block.timestamp;

        // If disputeWindow == 0, immediately transition to RESOLVED
        if (pop.disputeWindow == 0) {
            _handleImmediateResolution(popId, pop, requiresBond, bondToken, bondAmount);
        } else {
            _handleStandardResolution(popId, pop, bondToken, bondAmount);
        }
    }

    /// @notice Internal helper to store resolution info
    function _storeResolutionInfo(
        uint256 popId,
        address resolver,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) internal {
        (bool boolResult, int256 numResult, bytes memory genResult) =
            IPopResolver(resolver).resolvePop(popId, msg.sender, payload);

        _resolutions[popId] = ResolutionInfo({
            proposer: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            proposedBooleanOutcome: boolResult,
            proposedNumericOutcome: numResult,
            proposedGenericOutcome: genResult
        });
    }

    /// @notice Handle immediate resolution (disputeWindow == 0)
    function _handleImmediateResolution(
        uint256 popId,
        POP storage pop,
        bool requiresBond,
        address bondToken,
        uint256 bondAmount
    ) internal {
        ResolutionInfo storage resolution = _resolutions[popId];

        pop.state = POPState.RESOLVED;
        pop.disputeDeadline = 0;
        pop.postDisputeDeadline = pop.postResolutionWindow > 0
            ? block.timestamp + pop.postResolutionWindow
            : 0;

        // Store result immediately
        _storeResult(popId, pop.answerType, resolution.proposedBooleanOutcome, resolution.proposedNumericOutcome, resolution.proposedGenericOutcome);

        // Return bond if it was posted (for undisputable POPs with postResolutionWindow == 0)
        if (requiresBond && pop.postResolutionWindow == 0) {
            _transferBondOut(msg.sender, bondToken, bondAmount);
            emit ResolutionBondReturned(popId, msg.sender, bondToken, bondAmount);
        }

        emit POPFinalized(popId, pop.answerType);
    }

    /// @notice Handle standard resolution (disputeWindow > 0)
    function _handleStandardResolution(
        uint256 popId,
        POP storage pop,
        address bondToken,
        uint256 bondAmount
    ) internal {
        pop.state = POPState.RESOLVING;
        pop.disputeDeadline = block.timestamp + pop.disputeWindow;

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

        // Check not already disputed
        if (_disputes[popId].disputer != address(0)) {
            revert AlreadyDisputed(popId);
        }

        // Get resolution info
        ResolutionInfo storage resolution = _resolutions[popId];

        // Finalize the POP
        pop.state = POPState.RESOLVED;

        // Set post-resolution dispute deadline
        pop.postDisputeDeadline = pop.postResolutionWindow > 0
            ? block.timestamp + pop.postResolutionWindow
            : 0;

        // Store the final result
        _storeResult(popId, pop.answerType, resolution.proposedBooleanOutcome, resolution.proposedNumericOutcome, resolution.proposedGenericOutcome);

        // Return resolution bond to proposer (unless there's a post-resolution window)
        if (pop.postResolutionWindow == 0) {
            _transferBondOut(resolution.proposer, resolution.bondToken, resolution.bondAmount);
            emit ResolutionBondReturned(popId, resolution.proposer, resolution.bondToken, resolution.bondAmount);
        }

        emit POPFinalized(popId, pop.answerType);
    }

    // ============ Dispute System ============

    /// @inheritdoc IPOPRegistry
    function dispute(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bool proposedBooleanResult,
        int256 proposedNumericResult,
        bytes calldata proposedGenericResult
    ) external payable nonReentrant validPopId(popId) {
        POP storage pop = _pops[popId];

        // Check not already disputed
        if (_disputes[popId].disputer != address(0)) {
            revert AlreadyDisputed(popId);
        }

        DisputePhase phase;

        if (pop.state == POPState.RESOLVING) {
            // Pre-resolution dispute
            if (block.timestamp >= pop.disputeDeadline) {
                revert DisputeWindowPassed(pop.disputeDeadline, block.timestamp);
            }
            phase = DisputePhase.PRE_RESOLUTION;
            pop.state = POPState.DISPUTED_ROUND_1;
            // Set TruthKeeper deadline
            pop.truthKeeperDeadline = block.timestamp + pop.truthKeeperWindow;

        } else if (pop.state == POPState.RESOLVED) {
            // Post-resolution dispute
            if (pop.postDisputeDeadline == 0) {
                revert DisputeWindowPassed(0, block.timestamp);
            }
            if (block.timestamp >= pop.postDisputeDeadline) {
                revert DisputeWindowPassed(pop.postDisputeDeadline, block.timestamp);
            }
            phase = DisputePhase.POST_RESOLUTION;
            // State stays RESOLVED for post-resolution disputes

        } else {
            revert CannotDisputeInCurrentState(pop.state);
        }

        // Validate and transfer bond
        if (!_isAcceptableDisputeBond(bondToken, bondAmount)) {
            revert InvalidBond(bondToken, bondAmount);
        }
        _transferBondIn(bondToken, bondAmount);

        // Store dispute info with proposed answer
        _disputes[popId] = DisputeInfo({
            phase: phase,
            disputer: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            reason: reason,
            evidenceURI: evidenceURI,
            filedAt: block.timestamp,
            resolvedAt: 0,
            resultCorrected: false,
            proposedBooleanResult: proposedBooleanResult,
            proposedNumericResult: proposedNumericResult,
            proposedGenericResult: proposedGenericResult,
            tkDecision: DisputeResolution.UPHOLD_DISPUTE, // Default, will be set by TK
            tkDecidedAt: 0
        });

        emit DisputeBondDeposited(popId, msg.sender, bondToken, bondAmount);

        if (phase == DisputePhase.PRE_RESOLUTION) {
            emit POPDisputed(popId, msg.sender, reason);
        } else {
            emit PostResolutionDisputeFiled(popId, msg.sender, reason);
        }
    }

    /// @inheritdoc IPOPRegistry
    function challengeTruthKeeperDecision(
        uint256 popId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bool proposedBooleanResult,
        int256 proposedNumericResult,
        bytes calldata proposedGenericResult
    ) external payable nonReentrant validPopId(popId) {
        POP storage pop = _pops[popId];
        DisputeInfo storage disputeInfo = _disputes[popId];

        // Must be in DISPUTED_ROUND_1 with TK decision made
        if (pop.state != POPState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(pop.state);
        }
        if (disputeInfo.tkDecidedAt == 0) {
            revert TruthKeeperNotYetDecided(popId);
        }

        // Check escalation window
        if (block.timestamp >= pop.escalationDeadline) {
            revert EscalationWindowPassed(pop.escalationDeadline, block.timestamp);
        }

        // Check not already escalated
        if (_escalations[popId].challenger != address(0)) {
            revert AlreadyEscalated(popId);
        }

        // Validate escalation bond (higher than dispute bond)
        if (!_isAcceptableEscalationBond(bondToken, bondAmount)) {
            revert InvalidBond(bondToken, bondAmount);
        }
        _transferBondIn(bondToken, bondAmount);

        // Store escalation info
        _escalations[popId] = EscalationInfo({
            challenger: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            reason: reason,
            evidenceURI: evidenceURI,
            filedAt: block.timestamp,
            resolvedAt: 0,
            proposedBooleanResult: proposedBooleanResult,
            proposedNumericResult: proposedNumericResult,
            proposedGenericResult: proposedGenericResult
        });

        // Move to Round 2
        pop.state = POPState.DISPUTED_ROUND_2;

        emit TruthKeeperDecisionChallenged(popId, msg.sender, reason);
    }

    /// @inheritdoc IPOPRegistry
    function finalizeAfterTruthKeeper(uint256 popId) external nonReentrant validPopId(popId) {
        POP storage pop = _pops[popId];
        DisputeInfo storage disputeInfo = _disputes[popId];

        if (pop.state != POPState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(pop.state);
        }

        // TK must have decided
        if (disputeInfo.tkDecidedAt == 0) {
            revert TruthKeeperNotYetDecided(popId);
        }

        // Escalation window must have passed
        if (block.timestamp < pop.escalationDeadline) {
            revert EscalationWindowNotPassed(pop.escalationDeadline, block.timestamp);
        }

        // Must not have been escalated
        if (_escalations[popId].challenger != address(0)) {
            revert AlreadyEscalated(popId);
        }

        // Apply TK's decision
        _applyTruthKeeperDecision(popId, pop, disputeInfo);
    }

    /// @inheritdoc IPOPRegistry
    function escalateTruthKeeperTimeout(uint256 popId) external nonReentrant validPopId(popId) {
        POP storage pop = _pops[popId];
        DisputeInfo storage disputeInfo = _disputes[popId];

        if (pop.state != POPState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(pop.state);
        }

        // TK must NOT have decided
        if (disputeInfo.tkDecidedAt != 0) {
            revert TruthKeeperAlreadyDecided(popId);
        }

        // TK window must have passed
        if (block.timestamp < pop.truthKeeperDeadline) {
            revert TruthKeeperWindowNotPassed(pop.truthKeeperDeadline, block.timestamp);
        }

        // Auto-escalate to Round 2
        pop.state = POPState.DISPUTED_ROUND_2;

        emit TruthKeeperTimedOut(popId, pop.truthKeeper);
    }

    /// @inheritdoc IPOPRegistry
    function resolveEscalation(
        uint256 popId,
        DisputeResolution resolution,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult
    ) external onlyOwner nonReentrant validPopId(popId) {
        POP storage pop = _pops[popId];

        if (pop.state != POPState.DISPUTED_ROUND_2) {
            revert NotInDisputedRound2State(pop.state);
        }

        EscalationInfo storage escalationInfo = _escalations[popId];
        DisputeInfo storage disputeInfo = _disputes[popId];
        ResolutionInfo storage resolutionInfo = _resolutions[popId];

        escalationInfo.resolvedAt = block.timestamp;
        disputeInfo.resolvedAt = block.timestamp;

        if (resolution == DisputeResolution.TOO_EARLY) {
            _handleTooEarlyResolution(popId, pop, disputeInfo);
        } else if (resolution == DisputeResolution.CANCEL_POP) {
            // Return all bonds
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            _transferBondOut(escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
            pop.state = POPState.CANCELLED;
            emit POPCancelled(popId, "Escalation cancelled");
        } else if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
            // Challenger wins - disputer was right all along
            disputeInfo.resultCorrected = true;

            // Set corrected result
            _storeResult(popId, pop.answerType, correctedBooleanResult, correctedNumericResult, correctedGenericResult);

            // Bond economics: challenger gets back + 50% of TK-side bond
            // Original disputer also gets rewarded
            _transferBondOut(escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
            _slashBondWithReward(popId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            pop.state = POPState.RESOLVED;
            pop.resolutionTime = block.timestamp;
            if (pop.postResolutionWindow > 0) {
                pop.postDisputeDeadline = block.timestamp + pop.postResolutionWindow;
            }
        } else {
            // REJECT_DISPUTE - TK was right
            // Return proposer bond, slash challenger, reward TK-side winner
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _slashBondWithReward(popId, escalationInfo.challenger, disputeInfo.disputer, escalationInfo.bondToken, escalationInfo.bondAmount);
            _slashBondWithReward(popId, disputeInfo.disputer, resolutionInfo.proposer, disputeInfo.bondToken, disputeInfo.bondAmount);

            pop.state = POPState.RESOLVED;
            pop.resolutionTime = block.timestamp;
            if (pop.postResolutionWindow > 0) {
                pop.postDisputeDeadline = block.timestamp + pop.postResolutionWindow;
            }
        }

        emit EscalationResolved(popId, resolution, msg.sender);
    }

    /// @inheritdoc IPOPRegistry
    function resolveDispute(
        uint256 popId,
        DisputeResolution resolution,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult
    ) external onlyOwner nonReentrant validPopId(popId) {
        DisputeInfo storage disputeInfo = _disputes[popId];

        // Validate dispute exists
        if (disputeInfo.disputer == address(0)) {
            revert NoDisputeExists(popId);
        }
        // Validate dispute not already resolved
        if (disputeInfo.resolvedAt != 0) {
            revert DisputeAlreadyResolved(popId);
        }

        POP storage pop = _pops[popId];
        ResolutionInfo storage resolutionInfo = _resolutions[popId];

        // For pre-resolution disputes, use resolveEscalation (Round 2) instead
        // This function now only handles post-resolution disputes
        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) {
            revert NotInDisputedRound2State(pop.state);
        }

        disputeInfo.resolvedAt = block.timestamp;

        // Post-resolution dispute handling only
        if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
            disputeInfo.resultCorrected = true;

            // Post-resolution: store corrected result in separate mappings
            _storePostResolutionCorrectedResult(popId, pop.answerType, correctedBooleanResult, correctedNumericResult, correctedGenericResult, disputeInfo);

            // Slash resolution bond with 50/50 split
            _slashBondWithReward(popId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            // Return dispute bond to disputer
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(popId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            emit PostResolutionDisputeResolved(popId, true);

        } else if (resolution == DisputeResolution.REJECT_DISPUTE) {
            disputeInfo.resultCorrected = false;

            // Post-resolution: original result stands, nothing changes
            // Slash dispute bond with 50/50 split
            _slashBondWithReward(popId, resolutionInfo.proposer, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            // Return resolution bond to proposer
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(popId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            emit PostResolutionDisputeResolved(popId, false);

        } else if (resolution == DisputeResolution.CANCEL_POP) {
            // Cancel - set state and return both bonds
            pop.state = POPState.CANCELLED;

            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(popId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(popId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            emit POPCancelled(popId, "Admin cancelled during post-resolution dispute");

        } else if (resolution == DisputeResolution.TOO_EARLY) {
            // TOO_EARLY doesn't make sense for post-resolution, treat as cancel
            pop.state = POPState.CANCELLED;

            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit POPCancelled(popId, "Invalid resolution for post-resolution dispute");
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
        bool resolverIsActive;

        // Handle deprecated resolvers - check which set they belong to
        if (resolverType == ResolverType.SYSTEM ||
            (resolverType == ResolverType.DEPRECATED && _systemResolvers.contains(pop.resolver))) {
            resolverId = _systemResolverToId[pop.resolver];
            resolverIsActive = _systemResolverConfigs[pop.resolver].isActive;
        } else {
            resolverId = _publicResolverToId[pop.resolver];
            resolverIsActive = _publicResolverConfigs[pop.resolver].isActive;
        }

        info = POPInfo({
            resolver: pop.resolver,
            state: pop.state,
            answerType: pop.answerType,
            resolutionTime: pop.resolutionTime,
            disputeWindow: pop.disputeWindow,
            truthKeeperWindow: pop.truthKeeperWindow,
            escalationWindow: pop.escalationWindow,
            postResolutionWindow: pop.postResolutionWindow,
            disputeDeadline: pop.disputeDeadline,
            truthKeeperDeadline: pop.truthKeeperDeadline,
            escalationDeadline: pop.escalationDeadline,
            postDisputeDeadline: pop.postDisputeDeadline,
            truthKeeper: pop.truthKeeper,
            tierAtCreation: pop.tierAtCreation,
            isResolved: pop.state == POPState.RESOLVED,
            booleanResult: _hasCorrectedResult[popId] ? _correctedBooleanResults[popId] : _booleanResults[popId],
            numericResult: _hasCorrectedResult[popId] ? _correctedNumericResults[popId] : _numericResults[popId],
            genericResult: _hasCorrectedResult[popId] ? _correctedGenericResults[popId] : _genericResults[popId],
            hasCorrectedResult: _hasCorrectedResult[popId],
            correctedBooleanResult: _correctedBooleanResults[popId],
            correctedNumericResult: _correctedNumericResults[popId],
            correctedGenericResult: _correctedGenericResults[popId],
            resolverType: resolverType,
            resolverId: resolverId,
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
        if (_hasCorrectedResult[popId]) {
            return _correctedBooleanResults[popId];
        }
        return _booleanResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getNumericResult(uint256 popId) external view validPopId(popId) returns (int256 result) {
        if (_hasCorrectedResult[popId]) {
            return _correctedNumericResults[popId];
        }
        return _numericResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getGenericResult(uint256 popId) external view validPopId(popId) returns (bytes memory result) {
        if (_hasCorrectedResult[popId]) {
            return _correctedGenericResults[popId];
        }
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

    // ============ Flexible Dispute Window View Functions ============

    /// @inheritdoc IPOPRegistry
    function isFullyFinalized(uint256 popId) external view validPopId(popId) returns (bool) {
        POP storage pop = _pops[popId];

        if (pop.state != POPState.RESOLVED) {
            return false;
        }

        // Check if post-resolution dispute window is still open
        if (pop.postDisputeDeadline > 0 && block.timestamp < pop.postDisputeDeadline) {
            // Window still open, check if already disputed
            if (_disputes[popId].disputer == address(0)) {
                return false; // Can still be disputed
            }
            // Disputed but not yet resolved
            if (_disputes[popId].resolvedAt == 0) {
                return false;
            }
        }

        return true;
    }

    /// @inheritdoc IPOPRegistry
    function isContested(uint256 popId) external view validPopId(popId) returns (bool) {
        DisputeInfo storage disputeInfo = _disputes[popId];
        return disputeInfo.phase == DisputePhase.POST_RESOLUTION && disputeInfo.disputer != address(0);
    }

    /// @inheritdoc IPOPRegistry
    function hasCorrectedResult(uint256 popId) external view validPopId(popId) returns (bool) {
        return _hasCorrectedResult[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getCorrectedBooleanResult(uint256 popId) external view validPopId(popId) returns (bool result) {
        return _correctedBooleanResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getCorrectedNumericResult(uint256 popId) external view validPopId(popId) returns (int256 result) {
        return _correctedNumericResults[popId];
    }

    /// @inheritdoc IPOPRegistry
    function getCorrectedGenericResult(uint256 popId) external view validPopId(popId) returns (bytes memory result) {
        return _correctedGenericResults[popId];
    }

    // ============ TruthKeeper View Functions ============

    /// @inheritdoc IPOPRegistry
    function isWhitelistedTruthKeeper(address tk) external view returns (bool) {
        return _whitelistedTruthKeepers.contains(tk);
    }

    /// @inheritdoc IPOPRegistry
    function isWhitelistedResolver(address resolver) external view returns (bool) {
        return _whitelistedResolvers.contains(resolver);
    }

    /// @inheritdoc IPOPRegistry
    function getTruthKeeperGuaranteedResolvers(address tk) external view returns (address[] memory) {
        return _tkGuaranteedResolvers[tk].values();
    }

    /// @inheritdoc IPOPRegistry
    function isTruthKeeperGuaranteedResolver(address tk, address resolver) external view returns (bool) {
        return _tkGuaranteedResolvers[tk].contains(resolver);
    }

    /// @inheritdoc IPOPRegistry
    function getEscalationInfo(uint256 popId) external view validPopId(popId) returns (EscalationInfo memory) {
        return _escalations[popId];
    }

    /// @inheritdoc IPOPRegistry
    function calculateAccountabilityTier(address resolver, address tk) external view returns (AccountabilityTier) {
        return _calculateAccountabilityTier(resolver, tk);
    }

    /// @inheritdoc IPOPRegistry
    function isAcceptableEscalationBond(address token, uint256 amount) external view returns (bool) {
        return _isAcceptableEscalationBond(token, amount);
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

    /// @notice Slash bond with 50% to winner, 50% to contract
    function _slashBondWithReward(
        uint256 popId,
        address winner,
        address loser,
        address token,
        uint256 amount
    ) internal {
        uint256 winnerShare = amount / 2;
        uint256 contractShare = amount - winnerShare; // Handles odd amounts

        // Transfer winner's share
        _transferBondOut(winner, token, winnerShare);

        // Contract keeps the rest
        emit BondSlashed(popId, loser, token, contractShare);
    }

    /// @notice Check if bond is acceptable for escalation
    function _isAcceptableEscalationBond(address token, uint256 amount) internal view returns (bool) {
        for (uint256 i = 0; i < _acceptableEscalationBonds.length; i++) {
            if (_acceptableEscalationBonds[i].token == token &&
                amount >= _acceptableEscalationBonds[i].minAmount) {
                return true;
            }
        }
        return false;
    }

    /// @notice Calculate accountability tier for resolver + TK combination
    function _calculateAccountabilityTier(address resolver, address tk) internal view returns (AccountabilityTier) {
        if (_whitelistedResolvers.contains(resolver) && _whitelistedTruthKeepers.contains(tk)) {
            return AccountabilityTier.SYSTEM;
        }
        if (_tkGuaranteedResolvers[tk].contains(resolver)) {
            return AccountabilityTier.TK_GUARANTEED;
        }
        return AccountabilityTier.PERMISSIONLESS;
    }

    /// @notice Handle TOO_EARLY resolution - return to ACTIVE
    function _handleTooEarlyResolution(
        uint256 popId,
        POP storage pop,
        DisputeInfo storage disputeInfo
    ) internal {
        ResolutionInfo storage resolutionInfo = _resolutions[popId];

        // Slash proposer bond: 50% to disputer, 50% to contract
        _slashBondWithReward(popId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

        // Return disputer bond
        _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

        // Clear resolution info
        delete _resolutions[popId];

        // Reset dispute info
        disputeInfo.resolvedAt = block.timestamp;

        // Return to ACTIVE state
        pop.state = POPState.ACTIVE;
        pop.disputeDeadline = 0;
        pop.truthKeeperDeadline = 0;
        pop.escalationDeadline = 0;
    }

    /// @notice Apply TruthKeeper's decision after escalation window passes
    function _applyTruthKeeperDecision(
        uint256 popId,
        POP storage pop,
        DisputeInfo storage disputeInfo
    ) internal {
        ResolutionInfo storage resolutionInfo = _resolutions[popId];
        DisputeResolution decision = disputeInfo.tkDecision;

        disputeInfo.resolvedAt = block.timestamp;

        if (decision == DisputeResolution.TOO_EARLY) {
            // Already handled in resolveTruthKeeperDispute
            return;
        } else if (decision == DisputeResolution.CANCEL_POP) {
            // Return all bonds
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            pop.state = POPState.CANCELLED;
            emit POPCancelled(popId, "Cancelled by TruthKeeper");
        } else if (decision == DisputeResolution.UPHOLD_DISPUTE) {
            // Disputer wins
            disputeInfo.resultCorrected = true;

            // Set the disputer's proposed result
            _storeResult(popId, pop.answerType, disputeInfo.proposedBooleanResult, disputeInfo.proposedNumericResult, disputeInfo.proposedGenericResult);

            // Bond economics: disputer gets back + 50% of proposer bond
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            _slashBondWithReward(popId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            pop.state = POPState.RESOLVED;
            pop.resolutionTime = block.timestamp;
            if (pop.postResolutionWindow > 0) {
                pop.postDisputeDeadline = block.timestamp + pop.postResolutionWindow;
            }

            emit DisputeResolved(popId, decision, pop.truthKeeper);
        } else {
            // REJECT_DISPUTE - proposer was right
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _slashBondWithReward(popId, resolutionInfo.proposer, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            pop.state = POPState.RESOLVED;
            pop.resolutionTime = block.timestamp;
            if (pop.postResolutionWindow > 0) {
                pop.postDisputeDeadline = block.timestamp + pop.postResolutionWindow;
            }

            emit DisputeResolved(popId, decision, pop.truthKeeper);
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

    /// @notice Store result in the appropriate mapping
    function _storeResult(
        uint256 popId,
        AnswerType answerType,
        bool boolResult,
        int256 numResult,
        bytes memory genResult
    ) internal {
        if (answerType == AnswerType.BOOLEAN) {
            _booleanResults[popId] = boolResult;
        } else if (answerType == AnswerType.NUMERIC) {
            _numericResults[popId] = numResult;
        } else if (answerType == AnswerType.GENERIC) {
            _genericResults[popId] = genResult;
        }
    }

    /// @notice Store corrected result for pre-resolution dispute upheld
    /// @dev Priority: admin's answer > disputer's proposed > flip (for boolean)
    function _storeCorrectedResult(
        uint256 popId,
        AnswerType answerType,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult,
        DisputeInfo storage disputeInfo,
        ResolutionInfo storage resolutionInfo
    ) internal {
        if (answerType == AnswerType.BOOLEAN) {
            // For boolean: admin's if different from original, else disputer's, else flip
            bool result;
            if (correctedBooleanResult != resolutionInfo.proposedBooleanOutcome) {
                result = correctedBooleanResult;
            } else if (disputeInfo.proposedBooleanResult != resolutionInfo.proposedBooleanOutcome) {
                result = disputeInfo.proposedBooleanResult;
            } else {
                result = !resolutionInfo.proposedBooleanOutcome;
            }
            _booleanResults[popId] = result;
        } else if (answerType == AnswerType.NUMERIC) {
            // Use admin's if provided (non-zero or different from proposed), else disputer's
            int256 result;
            if (correctedNumericResult != 0 || correctedNumericResult != resolutionInfo.proposedNumericOutcome) {
                result = correctedNumericResult;
            } else if (disputeInfo.proposedNumericResult != 0) {
                result = disputeInfo.proposedNumericResult;
            } else {
                revert NoCorrectedAnswerProvided(popId);
            }
            _numericResults[popId] = result;
        } else if (answerType == AnswerType.GENERIC) {
            bytes memory result;
            if (correctedGenericResult.length > 0) {
                result = correctedGenericResult;
            } else if (disputeInfo.proposedGenericResult.length > 0) {
                result = disputeInfo.proposedGenericResult;
            } else {
                revert NoCorrectedAnswerProvided(popId);
            }
            _genericResults[popId] = result;
        }
    }

    /// @notice Store corrected result for post-resolution dispute upheld
    function _storePostResolutionCorrectedResult(
        uint256 popId,
        AnswerType answerType,
        bool correctedBooleanResult,
        int256 correctedNumericResult,
        bytes calldata correctedGenericResult,
        DisputeInfo storage disputeInfo
    ) internal {
        if (answerType == AnswerType.BOOLEAN) {
            // For boolean: admin's if different from original, else disputer's, else flip
            bool originalResult = _booleanResults[popId];
            bool result;
            if (correctedBooleanResult != originalResult) {
                result = correctedBooleanResult;
            } else if (disputeInfo.proposedBooleanResult != originalResult) {
                result = disputeInfo.proposedBooleanResult;
            } else {
                result = !originalResult;
            }
            _correctedBooleanResults[popId] = result;
            _hasCorrectedResult[popId] = true;
        } else if (answerType == AnswerType.NUMERIC) {
            int256 originalResult = _numericResults[popId];
            int256 result;
            if (correctedNumericResult != originalResult) {
                result = correctedNumericResult;
            } else if (disputeInfo.proposedNumericResult != originalResult) {
                result = disputeInfo.proposedNumericResult;
            } else {
                revert NoCorrectedAnswerProvided(popId);
            }
            _correctedNumericResults[popId] = result;
            _hasCorrectedResult[popId] = true;
        } else if (answerType == AnswerType.GENERIC) {
            bytes memory result;
            if (correctedGenericResult.length > 0) {
                result = correctedGenericResult;
            } else if (disputeInfo.proposedGenericResult.length > 0) {
                result = disputeInfo.proposedGenericResult;
            } else {
                revert NoCorrectedAnswerProvided(popId);
            }
            _correctedGenericResults[popId] = result;
            _hasCorrectedResult[popId] = true;
        }
    }
}
