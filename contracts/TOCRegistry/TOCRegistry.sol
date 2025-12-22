// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./TOCTypes.sol";
import "./ITOCRegistry.sol";
import "./ITOCResolver.sol";
import "./ITruthKeeper.sol";

/// @title TOCRegistry
/// @notice Central registry managing TOC lifecycle, resolvers, and disputes
/// @dev Implementation of ITOCRegistry with unified resolver trust system
contract TOCRegistry is ITOCRegistry, ReentrancyGuard, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Default dispute window if resolver doesn't specify one
    uint256 public constant DEFAULT_DISPUTE_WINDOW_DURATION = 24 hours;

    /// @notice Maximum window duration for RESOLVER trust level
    uint256 public constant MAX_WINDOW_RESOLVER = 1 days;

    /// @notice Maximum window duration for VERIFIED and SYSTEM trust levels
    uint256 public constant MAX_WINDOW_TRUSTED = 30 days;

    // ============ State Variables ============

    // Resolver storage (unified trust-based system)
    EnumerableSet.AddressSet private _registeredResolvers;
    mapping(address => ResolverConfig) private _resolverConfigs;

    // TOC storage
    mapping(uint256 => TOC) private _tocs;
    mapping(uint256 => DisputeInfo) private _disputes;
    mapping(uint256 => ResolutionInfo) private _resolutions;
    mapping(uint256 => bytes) private _results;
    uint256 private _nextTocId;

    // Corrected results flag (for post-resolution disputes)
    mapping(uint256 => bool) private _hasCorrectedResult;

    // Bond configuration
    BondRequirement[] private _acceptableResolutionBonds;
    BondRequirement[] private _acceptableDisputeBonds;
    BondRequirement[] private _acceptableEscalationBonds;

    // Settings
    uint256 private _defaultDisputeWindow;

    // TruthKeeper registry
    EnumerableSet.AddressSet private _whitelistedTruthKeepers;

    // Escalation info storage
    mapping(uint256 => EscalationInfo) private _escalations;

    // ============ Fee System Storage ============

    // Protocol configuration
    address public treasury;
    uint256 public protocolFeeMinimum;      // Fee when TK == address(0) - NOT USED currently (TK required)
    uint256 public protocolFeeStandard;     // Fee when TK assigned

    // TK share percentages (basis points, e.g., 4000 = 40%)
    mapping(AccountabilityTier => uint256) public tkSharePercent;

    // Protocol balances by category
    mapping(FeeCategory => uint256) public protocolBalances;

    // TK balances (aggregate per TK)
    mapping(address => uint256) public tkBalances;

    // Resolver fees (per TOC)
    mapping(uint256 => uint256) public resolverFeeByToc;

    // Resolver fee configuration (per resolver, per template)
    mapping(address => mapping(uint32 => uint256)) public resolverTemplateFees;

    // ============ Errors ============

    error ResolverNotRegistered(address resolver);
    error ResolverAlreadyRegistered(address resolver);
    error ResolverMustBeContract(address resolver);
    error InvalidTemplateId(uint32 templateId);
    error InvalidState(TOCState current, TOCState expected);
    error InvalidBond(address token, uint256 amount);
    error DisputeWindowNotPassed(uint256 deadline, uint256 current);
    error DisputeWindowPassed(uint256 deadline, uint256 current);
    error AlreadyDisputed(uint256 tocId);
    error NotResolver(address caller, address expected);
    error TransferFailed();
    error InsufficientValue(uint256 sent, uint256 required);
    error NoCorrectedAnswerProvided(uint256 tocId);
    error DisputeAlreadyResolved(uint256 tocId);
    error NoDisputeExists(uint256 tocId);
    error CannotDisputeInCurrentState(TOCState currentState);
    error NotTruthKeeper(address caller, address expected);
    error TruthKeeperNotWhitelisted(address tk);
    error TruthKeeperAlreadyWhitelisted(address tk);
    error TruthKeeperWindowNotPassed(uint256 deadline, uint256 current);
    error EscalationWindowNotPassed(uint256 deadline, uint256 current);
    error EscalationWindowPassed(uint256 deadline, uint256 current);
    error NotInDisputedRound1State(TOCState currentState);
    error NotInDisputedRound2State(TOCState currentState);
    error TruthKeeperAlreadyDecided(uint256 tocId);
    error TruthKeeperNotYetDecided(uint256 tocId);
    error AlreadyEscalated(uint256 tocId);
    error InvalidTruthKeeper(address tk);
    error NotFullyFinalized(uint256 tocId);
    error TruthKeeperNotContract(address tk);
    error TruthKeeperRejected(address tk, uint256 tocId);

    // Fee errors
    error TreasuryNotSet();
    error NotTreasury(address caller, address expected);
    error InsufficientFee(uint256 sent, uint256 required);
    error NoFeesToWithdraw();
    error NoResolverFee(uint256 tocId);
    error NotResolverForToc(address caller, uint256 tocId);

    // Window validation errors
    error WindowTooLong(uint256 provided, uint256 maximum);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        _defaultDisputeWindow = DEFAULT_DISPUTE_WINDOW_DURATION;
        _nextTocId = 1; // Start from 1, 0 means invalid
    }

    // ============ Modifiers ============

    modifier onlyResolver(uint256 tocId) {
        TOC storage toc = _tocs[tocId];
        if (msg.sender != toc.resolver) {
            revert NotResolver(msg.sender, toc.resolver);
        }
        _;
    }


    modifier inState(uint256 tocId, TOCState expected) {
        TOCState current = _tocs[tocId].state;
        if (current != expected) {
            revert InvalidState(current, expected);
        }
        _;
    }

    modifier onlyTruthKeeper(uint256 tocId) {
        TOC storage toc = _tocs[tocId];
        if (msg.sender != toc.truthKeeper) {
            revert NotTruthKeeper(msg.sender, toc.truthKeeper);
        }
        _;
    }

    modifier onlyTreasury() {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (msg.sender != treasury) revert NotTreasury(msg.sender, treasury);
        _;
    }

    // ============ Resolver Registration ============

    /// @inheritdoc ITOCRegistry
    function registerResolver(address resolver) external nonReentrant {
        if (resolver.code.length == 0) {
            revert ResolverMustBeContract(resolver);
        }
        if (_resolverConfigs[resolver].trust != ResolverTrust.NONE) {
            revert ResolverAlreadyRegistered(resolver);
        }

        _registeredResolvers.add(resolver);
        _resolverConfigs[resolver] = ResolverConfig({
            trust: ResolverTrust.RESOLVER,
            registeredAt: block.timestamp,
            registeredBy: msg.sender
        });

        emit ResolverRegistered(resolver, ResolverTrust.RESOLVER, msg.sender);
    }

    /// @inheritdoc ITOCRegistry
    function setResolverTrust(address resolver, ResolverTrust trust) external onlyOwner nonReentrant {
        if (_resolverConfigs[resolver].trust == ResolverTrust.NONE) {
            revert ResolverNotRegistered(resolver);
        }

        ResolverTrust oldTrust = _resolverConfigs[resolver].trust;
        _resolverConfigs[resolver].trust = trust;

        emit ResolverTrustChanged(resolver, oldTrust, trust);
    }

    // ============ Admin Functions ============

    /// @inheritdoc ITOCRegistry
    function addAcceptableResolutionBond(
        address token,
        uint256 minAmount
    ) external onlyOwner nonReentrant {
        _acceptableResolutionBonds.push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
    }

    /// @inheritdoc ITOCRegistry
    function addAcceptableDisputeBond(
        address token,
        uint256 minAmount
    ) external onlyOwner nonReentrant {
        _acceptableDisputeBonds.push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
    }

    /// @inheritdoc ITOCRegistry
    function setDefaultDisputeWindow(uint256 duration) external onlyOwner nonReentrant {
        _defaultDisputeWindow = duration;
    }

    /// @inheritdoc ITOCRegistry
    function addWhitelistedTruthKeeper(address tk) external onlyOwner nonReentrant {
        if (tk == address(0)) revert InvalidTruthKeeper(tk);
        if (_whitelistedTruthKeepers.contains(tk)) revert TruthKeeperAlreadyWhitelisted(tk);
        _whitelistedTruthKeepers.add(tk);
        emit TruthKeeperWhitelisted(tk);
    }

    /// @inheritdoc ITOCRegistry
    function removeWhitelistedTruthKeeper(address tk) external onlyOwner nonReentrant {
        if (!_whitelistedTruthKeepers.contains(tk)) revert TruthKeeperNotWhitelisted(tk);
        _whitelistedTruthKeepers.remove(tk);
        emit TruthKeeperRemovedFromWhitelist(tk);
    }

    /// @inheritdoc ITOCRegistry
    function addAcceptableEscalationBond(address token, uint256 minAmount) external onlyOwner nonReentrant {
        _acceptableEscalationBonds.push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
    }

    /// @inheritdoc ITOCRegistry
    function setTreasury(address _treasury) external onlyOwner nonReentrant {
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /// @inheritdoc ITOCRegistry
    function setProtocolFeeMinimum(uint256 amount) external onlyOwner nonReentrant {
        protocolFeeMinimum = amount;
        emit ProtocolFeeUpdated(protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITOCRegistry
    function setProtocolFeeStandard(uint256 amount) external onlyOwner nonReentrant {
        protocolFeeStandard = amount;
        emit ProtocolFeeUpdated(protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITOCRegistry
    function setTKSharePercent(AccountabilityTier tier, uint256 basisPoints) external onlyOwner nonReentrant {
        require(basisPoints <= 10000, "Basis points cannot exceed 100%");
        tkSharePercent[tier] = basisPoints;
        emit TKShareUpdated(tier, basisPoints);
    }

    // ============ TruthKeeper Functions ============

    /// @inheritdoc ITOCRegistry
    function resolveTruthKeeperDispute(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external nonReentrant onlyTruthKeeper(tocId) {
        TOC storage toc = _tocs[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(toc.state);
        }

        DisputeInfo storage disputeInfo = _disputes[tocId];

        if (disputeInfo.tkDecidedAt != 0) {
            revert TruthKeeperAlreadyDecided(tocId);
        }

        // Record TK decision
        disputeInfo.tkDecision = resolution;
        disputeInfo.tkDecidedAt = block.timestamp;

        // Set escalation deadline
        toc.escalationDeadline = block.timestamp + toc.escalationWindow;

        // Handle TOO_EARLY specially - immediately return to ACTIVE
        if (resolution == DisputeResolution.TOO_EARLY) {
            _handleTooEarlyResolution(tocId, toc, disputeInfo);
        }
        // Other resolutions wait for escalation window

        emit TruthKeeperDisputeResolved(tocId, msg.sender, resolution);
    }

    // ============ TOC Lifecycle ============

    /// @inheritdoc ITOCRegistry
    function createTOC(
        address resolver,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
    ) external payable nonReentrant returns (uint256 tocId) {
        // Check resolver is registered
        ResolverTrust trust = _resolverConfigs[resolver].trust;
        if (trust == ResolverTrust.NONE) {
            revert ResolverNotRegistered(resolver);
        }

        // Validate time windows don't exceed maximum for trust level
        uint256 maxWindow = (trust == ResolverTrust.RESOLVER)
            ? MAX_WINDOW_RESOLVER
            : MAX_WINDOW_TRUSTED;
        if (disputeWindow > maxWindow) revert WindowTooLong(disputeWindow, maxWindow);
        if (truthKeeperWindow > maxWindow) revert WindowTooLong(truthKeeperWindow, maxWindow);
        if (escalationWindow > maxWindow) revert WindowTooLong(escalationWindow, maxWindow);
        if (postResolutionWindow > maxWindow) revert WindowTooLong(postResolutionWindow, maxWindow);

        // Validate template exists on resolver
        if (!ITOCResolver(resolver).isValidTemplate(templateId)) {
            revert InvalidTemplateId(templateId);
        }

        // Verify TruthKeeper is a contract
        if (truthKeeper.code.length == 0) {
            revert TruthKeeperNotContract(truthKeeper);
        }

        // Generate TOC ID
        tocId = _nextTocId++;

        // Store TOC with user-specified dispute windows
        // Note: We inline some calls to avoid stack too deep
        TOC storage toc = _tocs[tocId];
        toc.resolver = resolver;
        toc.answerType = ITOCResolver(resolver).getTemplateAnswerType(templateId);
        toc.disputeWindow = disputeWindow;
        toc.truthKeeperWindow = truthKeeperWindow;
        toc.escalationWindow = escalationWindow;
        toc.postResolutionWindow = postResolutionWindow;
        toc.truthKeeper = truthKeeper;

        // Call TruthKeeper for approval
        TKApprovalResponse tkResponse = ITruthKeeper(truthKeeper).onTocAssigned(
            tocId,
            resolver,
            templateId,
            msg.sender,
            payload,
            uint32(disputeWindow),
            uint32(truthKeeperWindow),
            uint32(escalationWindow),
            uint32(postResolutionWindow)
        );

        // Handle TK response
        bool tkApproved;
        if (tkResponse == TKApprovalResponse.REJECT_HARD) {
            revert TruthKeeperRejected(truthKeeper, tocId);
        } else if (tkResponse == TKApprovalResponse.APPROVE) {
            tkApproved = true;
            emit TruthKeeperApproved(tocId, truthKeeper);
        } else {
            // REJECT_SOFT
            tkApproved = false;
            emit TruthKeeperSoftRejected(tocId, truthKeeper);
        }

        // Calculate tier with approval status
        toc.tierAtCreation = _calculateAccountabilityTier(resolver, truthKeeper, tkApproved);

        // Collect fees
        _collectCreationFees(tocId, resolver, templateId, truthKeeper, toc.tierAtCreation);

        // Call resolver to create TOC (may set initial state)
        toc.state = ITOCResolver(resolver).onTocCreated(tocId, templateId, payload, msg.sender);

        emit TOCCreated(tocId, resolver, trust, templateId, toc.answerType, toc.state, truthKeeper, toc.tierAtCreation);
    }

    /// @inheritdoc ITOCRegistry
    function resolveTOC(
        uint256 tocId,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) external payable nonReentrant inState(tocId, TOCState.ACTIVE) {
        TOC storage toc = _tocs[tocId];

        // Bond is required only if any dispute window > 0
        bool requiresBond = toc.disputeWindow > 0 || toc.postResolutionWindow > 0;
        if (requiresBond) {
            if (!_isAcceptableResolutionBond(bondToken, bondAmount)) {
                revert InvalidBond(bondToken, bondAmount);
            }
            _transferBondIn(bondToken, bondAmount);
        }

        // Call resolver to get typed outcome and store resolution
        _storeResolutionInfo(tocId, toc.resolver, bondToken, bondAmount, payload);

        toc.resolutionTime = block.timestamp;

        // If disputeWindow == 0, immediately transition to RESOLVED
        if (toc.disputeWindow == 0) {
            _handleImmediateResolution(tocId, toc, requiresBond, bondToken, bondAmount);
        } else {
            _handleStandardResolution(tocId, toc, bondToken, bondAmount);
        }
    }

    /// @notice Internal helper to store resolution info
    function _storeResolutionInfo(
        uint256 tocId,
        address resolver,
        address bondToken,
        uint256 bondAmount,
        bytes calldata payload
    ) internal {
        bytes memory result = ITOCResolver(resolver).resolveToc(tocId, msg.sender, payload);

        _resolutions[tocId] = ResolutionInfo({
            proposer: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            proposedResult: result
        });
    }

    /// @notice Handle immediate resolution (disputeWindow == 0)
    function _handleImmediateResolution(
        uint256 tocId,
        TOC storage toc,
        bool requiresBond,
        address bondToken,
        uint256 bondAmount
    ) internal {
        ResolutionInfo storage resolution = _resolutions[tocId];

        toc.state = TOCState.RESOLVED;
        toc.disputeDeadline = 0;
        toc.postDisputeDeadline = toc.postResolutionWindow > 0
            ? block.timestamp + toc.postResolutionWindow
            : 0;

        // Store result immediately
        _results[tocId] = resolution.proposedResult;

        // Return bond if it was posted (for undisputable TOCs with postResolutionWindow == 0)
        if (requiresBond && toc.postResolutionWindow == 0) {
            _transferBondOut(msg.sender, bondToken, bondAmount);
            emit ResolutionBondReturned(tocId, msg.sender, bondToken, bondAmount);
        }

        emit TOCFinalized(tocId, toc.answerType);
    }

    /// @notice Handle standard resolution (disputeWindow > 0)
    function _handleStandardResolution(
        uint256 tocId,
        TOC storage toc,
        address bondToken,
        uint256 bondAmount
    ) internal {
        toc.state = TOCState.RESOLVING;
        toc.disputeDeadline = block.timestamp + toc.disputeWindow;

        emit ResolutionBondDeposited(tocId, msg.sender, bondToken, bondAmount);
        emit TOCResolutionProposed(tocId, msg.sender, toc.answerType, toc.disputeDeadline);
    }

    /// @inheritdoc ITOCRegistry
    function finalizeTOC(uint256 tocId) external nonReentrant inState(tocId, TOCState.RESOLVING) {
        TOC storage toc = _tocs[tocId];

        // Check dispute window has passed
        if (block.timestamp < toc.disputeDeadline) {
            revert DisputeWindowNotPassed(toc.disputeDeadline, block.timestamp);
        }

        // Check not already disputed
        if (_disputes[tocId].disputer != address(0)) {
            revert AlreadyDisputed(tocId);
        }

        // Get resolution info
        ResolutionInfo storage resolution = _resolutions[tocId];

        // Finalize the TOC
        toc.state = TOCState.RESOLVED;

        // Set post-resolution dispute deadline
        toc.postDisputeDeadline = toc.postResolutionWindow > 0
            ? block.timestamp + toc.postResolutionWindow
            : 0;

        // Store the final result
        _results[tocId] = resolution.proposedResult;

        // Return resolution bond to proposer (unless there's a post-resolution window)
        if (toc.postResolutionWindow == 0) {
            _transferBondOut(resolution.proposer, resolution.bondToken, resolution.bondAmount);
            emit ResolutionBondReturned(tocId, resolution.proposer, resolution.bondToken, resolution.bondAmount);
        }

        emit TOCFinalized(tocId, toc.answerType);
    }

    // ============ Dispute System ============

    /// @inheritdoc ITOCRegistry
    function dispute(
        uint256 tocId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bytes calldata proposedResult
    ) external payable nonReentrant {
        TOC storage toc = _tocs[tocId];

        // Check not already disputed
        if (_disputes[tocId].disputer != address(0)) {
            revert AlreadyDisputed(tocId);
        }

        DisputePhase phase;

        if (toc.state == TOCState.RESOLVING) {
            // Pre-resolution dispute
            if (block.timestamp >= toc.disputeDeadline) {
                revert DisputeWindowPassed(toc.disputeDeadline, block.timestamp);
            }
            phase = DisputePhase.PRE_RESOLUTION;
            toc.state = TOCState.DISPUTED_ROUND_1;
            // Set TruthKeeper deadline
            toc.truthKeeperDeadline = block.timestamp + toc.truthKeeperWindow;

        } else if (toc.state == TOCState.RESOLVED) {
            // Post-resolution dispute
            if (toc.postDisputeDeadline == 0) {
                revert DisputeWindowPassed(0, block.timestamp);
            }
            if (block.timestamp >= toc.postDisputeDeadline) {
                revert DisputeWindowPassed(toc.postDisputeDeadline, block.timestamp);
            }
            phase = DisputePhase.POST_RESOLUTION;
            // State stays RESOLVED for post-resolution disputes

        } else {
            revert CannotDisputeInCurrentState(toc.state);
        }

        // Validate and transfer bond
        if (!_isAcceptableDisputeBond(bondToken, bondAmount)) {
            revert InvalidBond(bondToken, bondAmount);
        }
        _transferBondIn(bondToken, bondAmount);

        // Store dispute info with proposed answer
        _disputes[tocId] = DisputeInfo({
            phase: phase,
            disputer: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            reason: reason,
            evidenceURI: evidenceURI,
            filedAt: block.timestamp,
            resolvedAt: 0,
            resultCorrected: false,
            proposedResult: proposedResult,
            tkDecision: DisputeResolution.UPHOLD_DISPUTE, // Default, will be set by TK
            tkDecidedAt: 0
        });

        emit DisputeBondDeposited(tocId, msg.sender, bondToken, bondAmount);

        if (phase == DisputePhase.PRE_RESOLUTION) {
            emit TOCDisputed(tocId, msg.sender, reason);
        } else {
            emit PostResolutionDisputeFiled(tocId, msg.sender, reason);
        }
    }

    /// @inheritdoc ITOCRegistry
    function challengeTruthKeeperDecision(
        uint256 tocId,
        address bondToken,
        uint256 bondAmount,
        string calldata reason,
        string calldata evidenceURI,
        bytes calldata proposedResult
    ) external payable nonReentrant {
        TOC storage toc = _tocs[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];

        // Must be in DISPUTED_ROUND_1 with TK decision made
        if (toc.state != TOCState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(toc.state);
        }
        if (disputeInfo.tkDecidedAt == 0) {
            revert TruthKeeperNotYetDecided(tocId);
        }

        // Check escalation window
        if (block.timestamp >= toc.escalationDeadline) {
            revert EscalationWindowPassed(toc.escalationDeadline, block.timestamp);
        }

        // Check not already escalated
        if (_escalations[tocId].challenger != address(0)) {
            revert AlreadyEscalated(tocId);
        }

        // Validate escalation bond (higher than dispute bond)
        if (!_isAcceptableEscalationBond(bondToken, bondAmount)) {
            revert InvalidBond(bondToken, bondAmount);
        }
        _transferBondIn(bondToken, bondAmount);

        // Store escalation info
        _escalations[tocId] = EscalationInfo({
            challenger: msg.sender,
            bondToken: bondToken,
            bondAmount: bondAmount,
            reason: reason,
            evidenceURI: evidenceURI,
            filedAt: block.timestamp,
            resolvedAt: 0,
            proposedResult: proposedResult
        });

        // Move to Round 2
        toc.state = TOCState.DISPUTED_ROUND_2;

        emit TruthKeeperDecisionChallenged(tocId, msg.sender, reason);
    }

    /// @inheritdoc ITOCRegistry
    function finalizeAfterTruthKeeper(uint256 tocId) external nonReentrant {
        TOC storage toc = _tocs[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(toc.state);
        }

        // TK must have decided
        if (disputeInfo.tkDecidedAt == 0) {
            revert TruthKeeperNotYetDecided(tocId);
        }

        // Escalation window must have passed
        if (block.timestamp < toc.escalationDeadline) {
            revert EscalationWindowNotPassed(toc.escalationDeadline, block.timestamp);
        }

        // Must not have been escalated
        if (_escalations[tocId].challenger != address(0)) {
            revert AlreadyEscalated(tocId);
        }

        // Apply TK's decision
        _applyTruthKeeperDecision(tocId, toc, disputeInfo);
    }

    /// @inheritdoc ITOCRegistry
    function escalateTruthKeeperTimeout(uint256 tocId) external nonReentrant {
        TOC storage toc = _tocs[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_1) {
            revert NotInDisputedRound1State(toc.state);
        }

        // TK must NOT have decided
        if (disputeInfo.tkDecidedAt != 0) {
            revert TruthKeeperAlreadyDecided(tocId);
        }

        // TK window must have passed
        if (block.timestamp < toc.truthKeeperDeadline) {
            revert TruthKeeperWindowNotPassed(toc.truthKeeperDeadline, block.timestamp);
        }

        // Auto-escalate to Round 2
        toc.state = TOCState.DISPUTED_ROUND_2;

        emit TruthKeeperTimedOut(tocId, toc.truthKeeper);
    }

    /// @inheritdoc ITOCRegistry
    function resolveEscalation(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external onlyOwner nonReentrant {
        TOC storage toc = _tocs[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_2) {
            revert NotInDisputedRound2State(toc.state);
        }

        EscalationInfo storage escalationInfo = _escalations[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];
        ResolutionInfo storage resolutionInfo = _resolutions[tocId];

        escalationInfo.resolvedAt = block.timestamp;
        disputeInfo.resolvedAt = block.timestamp;

        if (resolution == DisputeResolution.TOO_EARLY) {
            _handleTooEarlyResolution(tocId, toc, disputeInfo);
        } else if (resolution == DisputeResolution.CANCEL_TOC) {
            // Return all bonds
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            _transferBondOut(escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
            toc.state = TOCState.CANCELLED;
            emit TOCCancelled(tocId, "Escalation cancelled");
        } else if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
            // Challenger wins - disputer was right all along
            disputeInfo.resultCorrected = true;

            // Set corrected result
            _results[tocId] = correctedResult;
            _hasCorrectedResult[tocId] = true;

            // Bond economics: challenger gets back + 50% of TK-side bond
            // Original disputer also gets rewarded
            _transferBondOut(escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
            _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            toc.state = TOCState.RESOLVED;
            toc.resolutionTime = block.timestamp;
            if (toc.postResolutionWindow > 0) {
                toc.postDisputeDeadline = block.timestamp + toc.postResolutionWindow;
            }
        } else {
            // REJECT_DISPUTE - TK was right
            // Return proposer bond, slash challenger, reward TK-side winner
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _slashBondWithReward(tocId, escalationInfo.challenger, disputeInfo.disputer, escalationInfo.bondToken, escalationInfo.bondAmount);
            _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, disputeInfo.bondToken, disputeInfo.bondAmount);

            toc.state = TOCState.RESOLVED;
            toc.resolutionTime = block.timestamp;
            if (toc.postResolutionWindow > 0) {
                toc.postDisputeDeadline = block.timestamp + toc.postResolutionWindow;
            }
        }

        emit EscalationResolved(tocId, resolution, msg.sender);
    }

    /// @inheritdoc ITOCRegistry
    function resolveDispute(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external onlyOwner nonReentrant {
        DisputeInfo storage disputeInfo = _disputes[tocId];

        // Validate dispute exists
        if (disputeInfo.disputer == address(0)) {
            revert NoDisputeExists(tocId);
        }
        // Validate dispute not already resolved
        if (disputeInfo.resolvedAt != 0) {
            revert DisputeAlreadyResolved(tocId);
        }

        TOC storage toc = _tocs[tocId];
        ResolutionInfo storage resolutionInfo = _resolutions[tocId];

        // For pre-resolution disputes, use resolveEscalation (Round 2) instead
        // This function now only handles post-resolution disputes
        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) {
            revert NotInDisputedRound2State(toc.state);
        }

        disputeInfo.resolvedAt = block.timestamp;

        // Post-resolution dispute handling only
        if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
            disputeInfo.resultCorrected = true;

            // Post-resolution: store corrected result (overwrite existing)
            // Priority: admin's answer > disputer's proposed answer
            if (correctedResult.length > 0) {
                _results[tocId] = correctedResult;
            } else if (disputeInfo.proposedResult.length > 0) {
                _results[tocId] = disputeInfo.proposedResult;
            } else {
                revert NoCorrectedAnswerProvided(tocId);
            }
            _hasCorrectedResult[tocId] = true;

            // Slash resolution bond with 50/50 split
            _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            // Return dispute bond to disputer
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(tocId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            emit PostResolutionDisputeResolved(tocId, true);

        } else if (resolution == DisputeResolution.REJECT_DISPUTE) {
            disputeInfo.resultCorrected = false;

            // Post-resolution: original result stands, nothing changes
            // Slash dispute bond with 50/50 split
            _slashBondWithReward(tocId, resolutionInfo.proposer, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            // Return resolution bond to proposer
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(tocId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            emit PostResolutionDisputeResolved(tocId, false);

        } else if (resolution == DisputeResolution.CANCEL_TOC) {
            // Cancel - set state and return both bonds
            toc.state = TOCState.CANCELLED;

            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(tocId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(tocId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            emit TOCCancelled(tocId, "Admin cancelled during post-resolution dispute");

        } else if (resolution == DisputeResolution.TOO_EARLY) {
            // TOO_EARLY doesn't make sense for post-resolution, treat as cancel
            toc.state = TOCState.CANCELLED;

            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit TOCCancelled(tocId, "Invalid resolution for post-resolution dispute");
        }

        emit DisputeResolved(tocId, resolution, msg.sender);
    }

    // ============ Resolver Callbacks ============

    /// @inheritdoc ITOCRegistry
    function approveTOC(uint256 tocId) external nonReentrant onlyResolver(tocId) inState(tocId, TOCState.PENDING) {
        _tocs[tocId].state = TOCState.ACTIVE;
        emit TOCApproved(tocId);
    }

    /// @inheritdoc ITOCRegistry
    function rejectTOC(uint256 tocId, string calldata reason) external nonReentrant onlyResolver(tocId) inState(tocId, TOCState.PENDING) {
        _tocs[tocId].state = TOCState.REJECTED;
        emit TOCRejected(tocId, reason);
    }

    // ============ View Functions ============

    /// @inheritdoc ITOCRegistry
    function getTOC(uint256 tocId) external view returns (TOC memory) {
        return _tocs[tocId];
    }

    /// @inheritdoc ITOCRegistry
    function getTOCInfo(uint256 tocId) external view returns (TOCInfo memory info) {
        TOC storage toc = _tocs[tocId];

        info = TOCInfo({
            resolver: toc.resolver,
            state: toc.state,
            answerType: toc.answerType,
            resolutionTime: toc.resolutionTime,
            disputeWindow: toc.disputeWindow,
            truthKeeperWindow: toc.truthKeeperWindow,
            escalationWindow: toc.escalationWindow,
            postResolutionWindow: toc.postResolutionWindow,
            disputeDeadline: toc.disputeDeadline,
            truthKeeperDeadline: toc.truthKeeperDeadline,
            escalationDeadline: toc.escalationDeadline,
            postDisputeDeadline: toc.postDisputeDeadline,
            truthKeeper: toc.truthKeeper,
            tierAtCreation: toc.tierAtCreation,
            isResolved: toc.state == TOCState.RESOLVED,
            result: _results[tocId],
            hasCorrectedResult: _hasCorrectedResult[tocId],
            resolverTrust: _resolverConfigs[toc.resolver].trust
        });
    }

    /// @inheritdoc ITOCRegistry
    function getTocDetails(
        uint256 tocId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        TOC storage toc = _tocs[tocId];
        return ITOCResolver(toc.resolver).getTocDetails(tocId);
    }

    /// @inheritdoc ITOCRegistry
    function getTocQuestion(
        uint256 tocId
    ) external view returns (string memory question) {
        TOC storage toc = _tocs[tocId];
        return ITOCResolver(toc.resolver).getTocQuestion(tocId);
    }

    /// @inheritdoc ITOCRegistry
    function getResolverTrust(address resolver) external view returns (ResolverTrust) {
        return _resolverConfigs[resolver].trust;
    }

    /// @inheritdoc ITOCRegistry
    function isRegisteredResolver(address resolver) external view returns (bool) {
        return _resolverConfigs[resolver].trust != ResolverTrust.NONE;
    }

    /// @inheritdoc ITOCRegistry
    function getResolverConfig(address resolver) external view returns (ResolverConfig memory) {
        return _resolverConfigs[resolver];
    }

    /// @inheritdoc ITOCRegistry
    function getRegisteredResolvers() external view returns (address[] memory) {
        return _registeredResolvers.values();
    }

    /// @inheritdoc ITOCRegistry
    function getResolverCount() external view returns (uint256) {
        return _registeredResolvers.length();
    }

    /// @inheritdoc ITOCRegistry
    function getDisputeInfo(
        uint256 tocId
    ) external view returns (DisputeInfo memory info) {
        return _disputes[tocId];
    }

    /// @inheritdoc ITOCRegistry
    function getResolutionInfo(
        uint256 tocId
    ) external view returns (ResolutionInfo memory info) {
        return _resolutions[tocId];
    }

    /// @inheritdoc ITOCRegistry
    function getTOCResult(uint256 tocId) external view returns (TOCResult memory result) {
        TOC storage toc = _tocs[tocId];
        result = TOCResult({
            answerType: toc.answerType,
            isResolved: toc.state == TOCState.RESOLVED,
            result: _results[tocId]
        });
    }

    /// @inheritdoc ITOCRegistry
    function getResult(uint256 tocId) external view returns (bytes memory result) {
        return _results[tocId];
    }

    /// @inheritdoc ITOCRegistry
    function getOriginalResult(uint256 tocId) external view returns (bytes memory result) {
        return _resolutions[tocId].proposedResult;
    }

    /// @inheritdoc ITOCRegistry
    function isAcceptableResolutionBond(
        address token,
        uint256 amount
    ) external view returns (bool) {
        return _isAcceptableResolutionBond(token, amount);
    }

    /// @inheritdoc ITOCRegistry
    function isAcceptableDisputeBond(
        address token,
        uint256 amount
    ) external view returns (bool) {
        return _isAcceptableDisputeBond(token, amount);
    }

    /// @inheritdoc ITOCRegistry
    function nextTocId() external view returns (uint256) {
        return _nextTocId;
    }

    /// @inheritdoc ITOCRegistry
    function defaultDisputeWindow() external view returns (uint256) {
        return _defaultDisputeWindow;
    }

    /// @inheritdoc ITOCRegistry
    function getCreationFee(
        address resolver,
        uint32 templateId
    ) external view returns (uint256 protocolFee, uint256 resolverFee, uint256 total) {
        protocolFee = protocolFeeStandard;
        resolverFee = resolverTemplateFees[resolver][templateId];
        total = protocolFee + resolverFee;
    }

    /// @inheritdoc ITOCRegistry
    function getProtocolFees() external view returns (uint256 minimum, uint256 standard) {
        return (protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITOCRegistry
    function getTKSharePercent(AccountabilityTier tier) external view returns (uint256) {
        return tkSharePercent[tier];
    }

    /// @inheritdoc ITOCRegistry
    function getProtocolBalance(FeeCategory category) external view returns (uint256) {
        return protocolBalances[category];
    }

    /// @inheritdoc ITOCRegistry
    function getTKBalance(address tk) external view returns (uint256) {
        return tkBalances[tk];
    }

    /// @inheritdoc ITOCRegistry
    function getResolverFeeByToc(uint256 tocId) external view returns (uint256) {
        return resolverFeeByToc[tocId];
    }

    // ============ Flexible Dispute Window View Functions ============

    /// @inheritdoc ITOCRegistry
    function isFullyFinalized(uint256 tocId) external view returns (bool) {
        TOC storage toc = _tocs[tocId];

        if (toc.state != TOCState.RESOLVED) {
            return false;
        }

        // Check if post-resolution dispute window is still open
        if (toc.postDisputeDeadline > 0 && block.timestamp < toc.postDisputeDeadline) {
            // Window still open, check if already disputed
            if (_disputes[tocId].disputer == address(0)) {
                return false; // Can still be disputed
            }
            // Disputed but not yet resolved
            if (_disputes[tocId].resolvedAt == 0) {
                return false;
            }
        }

        return true;
    }

    /// @inheritdoc ITOCRegistry
    function isContested(uint256 tocId) external view returns (bool) {
        DisputeInfo storage disputeInfo = _disputes[tocId];
        return disputeInfo.phase == DisputePhase.POST_RESOLUTION && disputeInfo.disputer != address(0);
    }

    /// @inheritdoc ITOCRegistry
    function hasCorrectedResult(uint256 tocId) external view returns (bool) {
        return _hasCorrectedResult[tocId];
    }

    // ============ TruthKeeper View Functions ============

    /// @inheritdoc ITOCRegistry
    function isWhitelistedTruthKeeper(address tk) external view returns (bool) {
        return _whitelistedTruthKeepers.contains(tk);
    }

    /// @inheritdoc ITOCRegistry
    function getEscalationInfo(uint256 tocId) external view returns (EscalationInfo memory) {
        return _escalations[tocId];
    }

    /// @inheritdoc ITOCRegistry
    function isAcceptableEscalationBond(address token, uint256 amount) external view returns (bool) {
        return _isAcceptableEscalationBond(token, amount);
    }

    // ============ Resolver Fee Functions ============

    /// @inheritdoc ITOCRegistry
    function setResolverFee(uint32 templateId, uint256 amount) external nonReentrant {
        if (_resolverConfigs[msg.sender].trust == ResolverTrust.NONE) {
            revert ResolverNotRegistered(msg.sender);
        }
        resolverTemplateFees[msg.sender][templateId] = amount;
        emit ResolverFeeSet(msg.sender, templateId, amount);
    }

    /// @inheritdoc ITOCRegistry
    function getResolverFee(address resolver, uint32 templateId) external view returns (uint256) {
        return resolverTemplateFees[resolver][templateId];
    }

    // ============ Fee Withdrawal Functions ============

    /// @inheritdoc ITOCRegistry
    function withdrawProtocolFees() external onlyTreasury nonReentrant returns (uint256 creationFees, uint256 slashingFees) {
        creationFees = protocolBalances[FeeCategory.CREATION];
        slashingFees = protocolBalances[FeeCategory.SLASHING];

        uint256 total = creationFees + slashingFees;
        if (total == 0) revert NoFeesToWithdraw();

        protocolBalances[FeeCategory.CREATION] = 0;
        protocolBalances[FeeCategory.SLASHING] = 0;

        (bool success, ) = msg.sender.call{value: total}("");
        if (!success) revert TransferFailed();

        emit ProtocolFeesWithdrawn(msg.sender, creationFees, slashingFees);
    }

    /// @inheritdoc ITOCRegistry
    function withdrawProtocolFeesByCategory(FeeCategory category) external onlyTreasury nonReentrant returns (uint256 amount) {
        amount = protocolBalances[category];
        if (amount == 0) revert NoFeesToWithdraw();

        protocolBalances[category] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ProtocolFeesWithdrawn(
            msg.sender,
            category == FeeCategory.CREATION ? amount : 0,
            category == FeeCategory.SLASHING ? amount : 0
        );
    }

    /// @inheritdoc ITOCRegistry
    function withdrawTKFees() external nonReentrant {
        uint256 amount = tkBalances[msg.sender];
        if (amount == 0) revert NoFeesToWithdraw();

        tkBalances[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TKFeesWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc ITOCRegistry
    function claimResolverFee(uint256 tocId) external nonReentrant {
        TOC storage toc = _tocs[tocId];
        if (msg.sender != toc.resolver) {
            revert NotResolverForToc(msg.sender, tocId);
        }

        uint256 amount = resolverFeeByToc[tocId];
        if (amount == 0) revert NoResolverFee(tocId);

        resolverFeeByToc[tocId] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ResolverFeeClaimed(msg.sender, tocId, amount);
    }

    /// @inheritdoc ITOCRegistry
    function claimResolverFees(uint256[] calldata tocIds) external nonReentrant {
        uint256 totalAmount = 0;
        address resolver = address(0);

        for (uint256 i = 0; i < tocIds.length; i++) {
            uint256 tocId = tocIds[i];
            if (tocId == 0 || tocId >= _nextTocId) continue;

            TOC storage toc = _tocs[tocId];

            // All TOCs must belong to same resolver
            if (resolver == address(0)) {
                resolver = toc.resolver;
            }
            if (msg.sender != toc.resolver) continue;

            uint256 amount = resolverFeeByToc[tocId];
            if (amount > 0) {
                resolverFeeByToc[tocId] = 0;
                totalAmount += amount;
                emit ResolverFeeClaimed(msg.sender, tocId, amount);
            }
        }

        if (totalAmount == 0) revert NoFeesToWithdraw();

        (bool success, ) = msg.sender.call{value: totalAmount}("");
        if (!success) revert TransferFailed();
    }

    // ============ Consumer Result Functions ============

    /// @inheritdoc ITOCRegistry
    function getExtensiveResult(uint256 tocId) external view returns (ExtensiveResult memory result) {
        TOC storage toc = _tocs[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];

        result = ExtensiveResult({
            answerType: toc.answerType,
            result: _results[tocId],
            isFinalized: toc.state == TOCState.RESOLVED,
            wasDisputed: disputeInfo.disputer != address(0),
            wasCorrected: _hasCorrectedResult[tocId],
            resolvedAt: toc.resolutionTime,
            tier: toc.tierAtCreation,
            resolverTrust: _resolverConfigs[toc.resolver].trust
        });
    }

    /// @inheritdoc ITOCRegistry
    function getExtensiveResultStrict(uint256 tocId) external view returns (ExtensiveResult memory result) {
        TOC storage toc = _tocs[tocId];

        // Must be fully finalized
        if (toc.state != TOCState.RESOLVED) {
            revert NotFullyFinalized(tocId);
        }

        // Post-resolution dispute window must have passed
        if (toc.postDisputeDeadline > 0 && block.timestamp < toc.postDisputeDeadline) {
            revert NotFullyFinalized(tocId);
        }

        DisputeInfo storage disputeInfo = _disputes[tocId];

        result = ExtensiveResult({
            answerType: toc.answerType,
            result: _results[tocId],
            isFinalized: true,
            wasDisputed: disputeInfo.disputer != address(0),
            wasCorrected: _hasCorrectedResult[tocId],
            resolvedAt: toc.resolutionTime,
            tier: toc.tierAtCreation,
            resolverTrust: _resolverConfigs[toc.resolver].trust
        });
    }

    // ============ Internal Functions ============

    /// @notice Collect creation fees and distribute to protocol, TK, and resolver
    function _collectCreationFees(
        uint256 tocId,
        address resolver,
        uint32 templateId,
        address tk,
        AccountabilityTier tier
    ) internal {
        uint256 protocolFee = protocolFeeStandard;
        uint256 resolverFee = resolverTemplateFees[resolver][templateId];
        uint256 totalFee = protocolFee + resolverFee;

        // Check sufficient payment
        if (msg.value < totalFee) {
            revert InsufficientFee(msg.value, totalFee);
        }

        // Calculate TK share from protocol fee
        uint256 tkShare = (protocolFee * tkSharePercent[tier]) / 10000;
        uint256 protocolKeeps = protocolFee - tkShare;

        // Store fees
        protocolBalances[FeeCategory.CREATION] += protocolKeeps;
        if (tkShare > 0) {
            tkBalances[tk] += tkShare;
        }
        if (resolverFee > 0) {
            resolverFeeByToc[tocId] = resolverFee;
        }

        // Refund excess
        if (msg.value > totalFee) {
            (bool success, ) = msg.sender.call{value: msg.value - totalFee}("");
            if (!success) revert TransferFailed();
        }

        emit CreationFeesCollected(tocId, protocolKeeps, tkShare, resolverFee);
    }

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

    /// @notice Slash bond with 50% to winner, 50% to contract (shared with TK)
    function _slashBondWithReward(
        uint256 tocId,
        address winner,
        address loser,
        address token,
        uint256 amount
    ) internal {
        uint256 winnerShare = amount / 2;
        uint256 contractShare = amount - winnerShare; // Handles odd amounts

        // Transfer winner's share
        _transferBondOut(winner, token, winnerShare);

        // Split contract share with TK based on tier
        TOC storage toc = _tocs[tocId];
        uint256 tkShare = (contractShare * tkSharePercent[toc.tierAtCreation]) / 10000;
        uint256 protocolKeeps = contractShare - tkShare;

        // Store protocol portion
        protocolBalances[FeeCategory.SLASHING] += protocolKeeps;

        // Store TK portion (only if ETH - for now we only support ETH fees)
        if (tkShare > 0 && token == address(0)) {
            tkBalances[toc.truthKeeper] += tkShare;
        } else if (tkShare > 0) {
            // For non-ETH tokens, protocol keeps the TK share for now
            protocolBalances[FeeCategory.SLASHING] += tkShare;
        }

        emit SlashingFeesCollected(tocId, protocolKeeps, tkShare);
        emit BondSlashed(tocId, loser, token, contractShare);
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
    /// @param resolver The resolver address
    /// @param tk The TruthKeeper address
    /// @param tkApproved Whether the TK approved this TOC
    function _calculateAccountabilityTier(address resolver, address tk, bool tkApproved) internal view returns (AccountabilityTier) {
        // No approval = RESOLVER
        if (!tkApproved) {
            return AccountabilityTier.RESOLVER;
        }

        // SYSTEM tier: resolver has SYSTEM trust and TK is whitelisted and approved
        if (_resolverConfigs[resolver].trust == ResolverTrust.SYSTEM && _whitelistedTruthKeepers.contains(tk)) {
            return AccountabilityTier.SYSTEM;
        }

        // TK approved but not SYSTEM conditions = TK_GUARANTEED
        return AccountabilityTier.TK_GUARANTEED;
    }

    /// @notice Handle TOO_EARLY resolution - return to ACTIVE
    function _handleTooEarlyResolution(
        uint256 tocId,
        TOC storage toc,
        DisputeInfo storage disputeInfo
    ) internal {
        ResolutionInfo storage resolutionInfo = _resolutions[tocId];

        // Slash proposer bond: 50% to disputer, 50% to contract
        _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

        // Return disputer bond
        _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

        // Clear resolution info
        delete _resolutions[tocId];

        // Reset dispute info
        disputeInfo.resolvedAt = block.timestamp;

        // Return to ACTIVE state
        toc.state = TOCState.ACTIVE;
        toc.disputeDeadline = 0;
        toc.truthKeeperDeadline = 0;
        toc.escalationDeadline = 0;
    }

    /// @notice Apply TruthKeeper's decision after escalation window passes
    function _applyTruthKeeperDecision(
        uint256 tocId,
        TOC storage toc,
        DisputeInfo storage disputeInfo
    ) internal {
        ResolutionInfo storage resolutionInfo = _resolutions[tocId];
        DisputeResolution decision = disputeInfo.tkDecision;

        disputeInfo.resolvedAt = block.timestamp;

        if (decision == DisputeResolution.TOO_EARLY) {
            // Already handled in resolveTruthKeeperDispute
            return;
        } else if (decision == DisputeResolution.CANCEL_TOC) {
            // Return all bonds
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            toc.state = TOCState.CANCELLED;
            emit TOCCancelled(tocId, "Cancelled by TruthKeeper");
        } else if (decision == DisputeResolution.UPHOLD_DISPUTE) {
            // Disputer wins
            disputeInfo.resultCorrected = true;

            // Set the disputer's proposed result
            _results[tocId] = disputeInfo.proposedResult;
            _hasCorrectedResult[tocId] = true;

            // Bond economics: disputer gets back + 50% of proposer bond
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

            toc.state = TOCState.RESOLVED;
            toc.resolutionTime = block.timestamp;
            if (toc.postResolutionWindow > 0) {
                toc.postDisputeDeadline = block.timestamp + toc.postResolutionWindow;
            }

            emit DisputeResolved(tocId, decision, toc.truthKeeper);
        } else {
            // REJECT_DISPUTE - proposer was right
            _results[tocId] = resolutionInfo.proposedResult;

            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _slashBondWithReward(tocId, resolutionInfo.proposer, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            toc.state = TOCState.RESOLVED;
            toc.resolutionTime = block.timestamp;
            if (toc.postResolutionWindow > 0) {
                toc.postDisputeDeadline = block.timestamp + toc.postResolutionWindow;
            }

            emit DisputeResolved(tocId, decision, toc.truthKeeper);
        }
    }

}
