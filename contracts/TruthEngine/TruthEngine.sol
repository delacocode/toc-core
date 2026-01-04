// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./TOCTypes.sol";
import "./ITruthEngine.sol";
import "./ITOCResolver.sol";
import "./ITruthKeeper.sol";

/// @title TruthEngine
/// @notice Central registry managing TOC lifecycle, resolvers, and disputes
/// @dev Implementation of ITruthEngine with unified resolver trust system
contract TruthEngine is ITruthEngine, ReentrancyGuard, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // ============ Constants ============

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

    // Bond configuration (indexed by BondType)
    mapping(BondType => BondRequirement[]) private _acceptableBonds;

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

    // ============ Errors (consolidated for size optimization) ============

    // Authorization
    error Unauthorized();

    // Registration
    error NotRegistered();
    error AlreadyRegistered();
    error NotContract();

    // State/Timing
    error InvalidState();
    error WindowNotReady();
    error WindowPassed();
    error AlreadyExists();
    error NotReady();

    // Validation
    error InvalidTemplateId();
    error InvalidBond();
    error InvalidAddress();
    error WindowTooLong();

    // Transfers/Fees
    error TransferFailed();
    error Insufficient();
    error TreasuryNotSet();
    error NoFeesToWithdraw();

    // Disputes
    error NoCorrectedAnswer();
    error NotFinalized();
    error TruthKeeperRejected();

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        _defaultDisputeWindow = 24 hours;
        _nextTocId = 1; // Start from 1, 0 means invalid
    }

    // ============ Modifiers ============

    modifier onlyResolver(uint256 tocId) {
        if (msg.sender != _tocs[tocId].resolver) revert Unauthorized();
        _;
    }

    modifier inState(uint256 tocId, TOCState expected) {
        if (_tocs[tocId].state != expected) revert InvalidState();
        _;
    }

    modifier onlyTruthKeeper(uint256 tocId) {
        if (msg.sender != _tocs[tocId].truthKeeper) revert Unauthorized();
        _;
    }

    modifier onlyTreasury() {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (msg.sender != treasury) revert Unauthorized();
        _;
    }

    // ============ Resolver Registration ============

    /// @inheritdoc ITruthEngine
    function registerResolver(address resolver) external nonReentrant {
        if (resolver.code.length == 0) revert NotContract();
        if (_resolverConfigs[resolver].trust != ResolverTrust.NONE) revert AlreadyRegistered();

        _registeredResolvers.add(resolver);
        _resolverConfigs[resolver] = ResolverConfig({
            trust: ResolverTrust.RESOLVER,
            registeredAt: block.timestamp,
            registeredBy: msg.sender
        });

        emit ResolverRegistered(resolver, ResolverTrust.RESOLVER, msg.sender);
    }

    /// @inheritdoc ITruthEngine
    function setResolverTrust(address resolver, ResolverTrust trust) external onlyOwner nonReentrant {
        if (_resolverConfigs[resolver].trust == ResolverTrust.NONE) revert NotRegistered();

        ResolverTrust oldTrust = _resolverConfigs[resolver].trust;
        _resolverConfigs[resolver].trust = trust;

        emit ResolverTrustChanged(resolver, oldTrust, trust);
    }

    // ============ Admin Functions ============

    /// @inheritdoc ITruthEngine
    function addAcceptableBond(
        BondType bondType,
        address token,
        uint256 minAmount
    ) external onlyOwner nonReentrant {
        _acceptableBonds[bondType].push(BondRequirement({
            token: token,
            minAmount: minAmount
        }));
        emit AcceptableBondAdded(bondType, token, minAmount);
    }

    /// @inheritdoc ITruthEngine
    function setDefaultDisputeWindow(uint256 duration) external onlyOwner nonReentrant {
        uint256 oldDuration = _defaultDisputeWindow;
        _defaultDisputeWindow = duration;
        emit DefaultDisputeWindowChanged(oldDuration, duration);
    }

    /// @inheritdoc ITruthEngine
    function addWhitelistedTruthKeeper(address tk) external onlyOwner nonReentrant {
        if (tk == address(0)) revert InvalidAddress();
        if (_whitelistedTruthKeepers.contains(tk)) revert AlreadyRegistered();
        _whitelistedTruthKeepers.add(tk);
        emit TruthKeeperWhitelisted(tk);
    }

    /// @inheritdoc ITruthEngine
    function removeWhitelistedTruthKeeper(address tk) external onlyOwner nonReentrant {
        if (!_whitelistedTruthKeepers.contains(tk)) revert NotRegistered();
        _whitelistedTruthKeepers.remove(tk);
        emit TruthKeeperRemovedFromWhitelist(tk);
    }

    /// @inheritdoc ITruthEngine
    function setTreasury(address _treasury) external onlyOwner nonReentrant {
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /// @inheritdoc ITruthEngine
    function setProtocolFeeMinimum(uint256 amount) external onlyOwner nonReentrant {
        protocolFeeMinimum = amount;
        emit ProtocolFeeUpdated(protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITruthEngine
    function setProtocolFeeStandard(uint256 amount) external onlyOwner nonReentrant {
        protocolFeeStandard = amount;
        emit ProtocolFeeUpdated(protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITruthEngine
    function setTKSharePercent(AccountabilityTier tier, uint256 basisPoints) external onlyOwner nonReentrant {
        if (basisPoints > 10000) revert InvalidBond(); // Reusing for general validation
        tkSharePercent[tier] = basisPoints;
        emit TKShareUpdated(tier, basisPoints);
    }

    // ============ TruthKeeper Functions ============

    /// @inheritdoc ITruthEngine
    function resolveTruthKeeperDispute(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external nonReentrant onlyTruthKeeper(tocId) {
        TOC storage toc = _tocs[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_1) revert InvalidState();

        DisputeInfo storage disputeInfo = _disputes[tocId];

        if (disputeInfo.tkDecidedAt != 0) revert AlreadyExists();

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

    /// @inheritdoc ITruthEngine
    function createTOC(
        address resolver,
        uint32 templateId,
        bytes calldata payload,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 escalationWindow,
        uint32 postResolutionWindow,
        address truthKeeper
    ) external payable nonReentrant returns (uint256 tocId) {
        // Check resolver is registered
        ResolverTrust trust = _resolverConfigs[resolver].trust;
        if (trust == ResolverTrust.NONE) revert NotRegistered();

        // Validate time windows don't exceed maximum for trust level
        uint256 maxWindow = (trust == ResolverTrust.RESOLVER)
            ? MAX_WINDOW_RESOLVER
            : MAX_WINDOW_TRUSTED;
        if (disputeWindow > maxWindow) revert WindowTooLong();
        if (truthKeeperWindow > maxWindow) revert WindowTooLong();
        if (escalationWindow > maxWindow) revert WindowTooLong();
        if (postResolutionWindow > maxWindow) revert WindowTooLong();

        // Validate template exists on resolver
        if (!ITOCResolver(resolver).isValidTemplate(templateId)) revert InvalidTemplateId();

        // Verify TruthKeeper is a contract
        if (truthKeeper.code.length == 0) revert NotContract();

        // Generate TOC ID
        tocId = _nextTocId++;

        // Store TOC with user-specified dispute windows
        // Note: We inline some calls to avoid stack too deep
        TOC storage toc = _tocs[tocId];
        toc.creator = msg.sender;
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
            revert TruthKeeperRejected();
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

        emit TOCCreated(
            tocId,
            resolver,
            msg.sender,
            trust,
            templateId,
            toc.answerType,
            toc.state,
            truthKeeper,
            toc.tierAtCreation,
            disputeWindow,
            truthKeeperWindow,
            escalationWindow,
            postResolutionWindow
        );
    }

    /// @inheritdoc ITruthEngine
    function transferCreator(uint256 tocId, address newCreator) external nonReentrant {
        TOC storage toc = _tocs[tocId];

        // Only current creator can transfer
        if (msg.sender != toc.creator) revert Unauthorized();

        // Can only transfer while ACTIVE (before resolution starts)
        if (toc.state != TOCState.ACTIVE) revert InvalidState();

        // New creator must be valid
        if (newCreator == address(0)) revert InvalidAddress();

        address previousCreator = toc.creator;
        toc.creator = newCreator;

        emit CreatorTransferred(tocId, previousCreator, newCreator);
    }

    /// @inheritdoc ITruthEngine
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
            if (!_isAcceptableBond(BondType.RESOLUTION, bondToken, bondAmount)) revert InvalidBond();
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

    /// @inheritdoc ITruthEngine
    function finalizeTOC(uint256 tocId) external nonReentrant inState(tocId, TOCState.RESOLVING) {
        TOC storage toc = _tocs[tocId];

        // Check dispute window has passed
        if (block.timestamp < toc.disputeDeadline) revert WindowNotReady();

        // Check not already disputed
        if (_disputes[tocId].disputer != address(0)) revert AlreadyExists();

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

    /// @inheritdoc ITruthEngine
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
        if (_disputes[tocId].disputer != address(0)) revert AlreadyExists();

        DisputePhase phase;

        if (toc.state == TOCState.RESOLVING) {
            // Pre-resolution dispute
            if (block.timestamp >= toc.disputeDeadline) revert WindowPassed();
            phase = DisputePhase.PRE_RESOLUTION;
            toc.state = TOCState.DISPUTED_ROUND_1;
            // Set TruthKeeper deadline
            toc.truthKeeperDeadline = block.timestamp + toc.truthKeeperWindow;

        } else if (toc.state == TOCState.RESOLVED) {
            // Post-resolution dispute
            if (toc.postDisputeDeadline == 0) revert WindowPassed();
            if (block.timestamp >= toc.postDisputeDeadline) revert WindowPassed();
            phase = DisputePhase.POST_RESOLUTION;
            // State stays RESOLVED for post-resolution disputes

        } else {
            revert InvalidState();
        }

        // Validate and transfer bond
        if (!_isAcceptableBond(BondType.DISPUTE, bondToken, bondAmount)) revert InvalidBond();
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
            emit TOCDisputed(tocId, msg.sender, reason, evidenceURI);
        } else {
            emit PostResolutionDisputeFiled(tocId, msg.sender, reason, evidenceURI, proposedResult);
        }
    }

    /// @inheritdoc ITruthEngine
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
        if (toc.state != TOCState.DISPUTED_ROUND_1) revert InvalidState();
        if (disputeInfo.tkDecidedAt == 0) revert NotReady();

        // Check escalation window
        if (block.timestamp >= toc.escalationDeadline) revert WindowPassed();

        // Check not already escalated
        if (_escalations[tocId].challenger != address(0)) revert AlreadyExists();

        // Validate escalation bond (higher than dispute bond)
        if (!_isAcceptableBond(BondType.ESCALATION, bondToken, bondAmount)) revert InvalidBond();
        _transferBondIn(bondToken, bondAmount);

        emit EscalationBondDeposited(tocId, msg.sender, bondToken, bondAmount);

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

        emit TruthKeeperDecisionChallenged(tocId, msg.sender, reason, evidenceURI, proposedResult);
    }

    /// @inheritdoc ITruthEngine
    function finalizeAfterTruthKeeper(uint256 tocId) external nonReentrant {
        TOC storage toc = _tocs[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_1) revert InvalidState();

        // TK must have decided
        if (disputeInfo.tkDecidedAt == 0) revert NotReady();

        // Escalation window must have passed
        if (block.timestamp < toc.escalationDeadline) revert WindowNotReady();

        // Must not have been escalated
        if (_escalations[tocId].challenger != address(0)) revert AlreadyExists();

        // Apply TK's decision
        _applyTruthKeeperDecision(tocId, toc, disputeInfo);
    }

    /// @inheritdoc ITruthEngine
    function escalateTruthKeeperTimeout(uint256 tocId) external nonReentrant {
        TOC storage toc = _tocs[tocId];
        DisputeInfo storage disputeInfo = _disputes[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_1) revert InvalidState();

        // TK must NOT have decided
        if (disputeInfo.tkDecidedAt != 0) revert AlreadyExists();

        // TK window must have passed
        if (block.timestamp < toc.truthKeeperDeadline) revert WindowNotReady();

        // Auto-escalate to Round 2
        toc.state = TOCState.DISPUTED_ROUND_2;

        emit TruthKeeperTimedOut(tocId, toc.truthKeeper);
    }

    /// @inheritdoc ITruthEngine
    function resolveEscalation(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external onlyOwner nonReentrant {
        TOC storage toc = _tocs[tocId];

        if (toc.state != TOCState.DISPUTED_ROUND_2) revert InvalidState();

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
            emit ResolutionBondReturned(tocId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(tocId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            _transferBondOut(escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
            emit EscalationBondReturned(tocId, escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
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
            emit EscalationBondReturned(tocId, escalationInfo.challenger, escalationInfo.bondToken, escalationInfo.bondAmount);
            _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
            emit DisputeBondReturned(tocId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

            toc.state = TOCState.RESOLVED;
            toc.resolutionTime = block.timestamp;
            if (toc.postResolutionWindow > 0) {
                toc.postDisputeDeadline = block.timestamp + toc.postResolutionWindow;
            }
        } else {
            // REJECT_DISPUTE - TK was right
            // Return proposer bond, slash challenger, reward TK-side winner
            _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            emit ResolutionBondReturned(tocId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
            _slashBondWithReward(tocId, escalationInfo.challenger, disputeInfo.disputer, escalationInfo.bondToken, escalationInfo.bondAmount);
            _slashBondWithReward(tocId, disputeInfo.disputer, resolutionInfo.proposer, disputeInfo.bondToken, disputeInfo.bondAmount);

            toc.state = TOCState.RESOLVED;
            toc.resolutionTime = block.timestamp;
            if (toc.postResolutionWindow > 0) {
                toc.postDisputeDeadline = block.timestamp + toc.postResolutionWindow;
            }
        }

        emit EscalationResolved(tocId, resolution, msg.sender, correctedResult);
    }

    /// @inheritdoc ITruthEngine
    function resolveDispute(
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external onlyOwner nonReentrant {
        DisputeInfo storage disputeInfo = _disputes[tocId];

        // Validate dispute exists
        if (disputeInfo.disputer == address(0)) revert NotReady();
        // Validate dispute not already resolved
        if (disputeInfo.resolvedAt != 0) revert AlreadyExists();

        TOC storage toc = _tocs[tocId];
        ResolutionInfo storage resolutionInfo = _resolutions[tocId];

        // For pre-resolution disputes, use resolveEscalation (Round 2) instead
        // This function now only handles post-resolution disputes
        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) revert InvalidState();

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
                revert NoCorrectedAnswer();
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

    /// @inheritdoc ITruthEngine
    function approveTOC(uint256 tocId) external nonReentrant onlyResolver(tocId) inState(tocId, TOCState.PENDING) {
        _tocs[tocId].state = TOCState.ACTIVE;
        emit TOCApproved(tocId);
    }

    /// @inheritdoc ITruthEngine
    function rejectTOC(uint256 tocId, string calldata reason) external nonReentrant onlyResolver(tocId) inState(tocId, TOCState.PENDING) {
        _tocs[tocId].state = TOCState.REJECTED;
        emit TOCRejected(tocId, reason);
    }

    // ============ View Functions ============

    /// @inheritdoc ITruthEngine
    function getTOC(uint256 tocId) external view returns (TOC memory) {
        return _tocs[tocId];
    }

    /// @inheritdoc ITruthEngine
    function getTOCInfo(uint256 tocId) external view returns (TOCInfo memory info) {
        TOC storage toc = _tocs[tocId];

        info = TOCInfo({
            creator: toc.creator,
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

    /// @inheritdoc ITruthEngine
    function getTocDetails(
        uint256 tocId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        TOC storage toc = _tocs[tocId];
        return ITOCResolver(toc.resolver).getTocDetails(tocId);
    }

    /// @inheritdoc ITruthEngine
    function getTocQuestion(
        uint256 tocId
    ) external view returns (string memory question) {
        TOC storage toc = _tocs[tocId];
        return ITOCResolver(toc.resolver).getTocQuestion(tocId);
    }

    /// @inheritdoc ITruthEngine
    function getResolverTrust(address resolver) external view returns (ResolverTrust) {
        return _resolverConfigs[resolver].trust;
    }

    /// @inheritdoc ITruthEngine
    function isRegisteredResolver(address resolver) external view returns (bool) {
        return _resolverConfigs[resolver].trust != ResolverTrust.NONE;
    }

    /// @inheritdoc ITruthEngine
    function getResolverConfig(address resolver) external view returns (ResolverConfig memory) {
        return _resolverConfigs[resolver];
    }

    /// @inheritdoc ITruthEngine
    function getRegisteredResolvers() external view returns (address[] memory) {
        return _registeredResolvers.values();
    }

    /// @inheritdoc ITruthEngine
    function getResolverCount() external view returns (uint256) {
        return _registeredResolvers.length();
    }

    /// @inheritdoc ITruthEngine
    function getDisputeInfo(
        uint256 tocId
    ) external view returns (DisputeInfo memory info) {
        return _disputes[tocId];
    }

    /// @inheritdoc ITruthEngine
    function getResolutionInfo(
        uint256 tocId
    ) external view returns (ResolutionInfo memory info) {
        return _resolutions[tocId];
    }

    /// @inheritdoc ITruthEngine
    function getTOCResult(uint256 tocId) external view returns (TOCResult memory result) {
        TOC storage toc = _tocs[tocId];
        result = TOCResult({
            answerType: toc.answerType,
            isResolved: toc.state == TOCState.RESOLVED,
            result: _results[tocId]
        });
    }

    /// @inheritdoc ITruthEngine
    function getResult(uint256 tocId) external view returns (bytes memory result) {
        return _results[tocId];
    }

    /// @inheritdoc ITruthEngine
    function getOriginalResult(uint256 tocId) external view returns (bytes memory result) {
        return _resolutions[tocId].proposedResult;
    }

    /// @inheritdoc ITruthEngine
    function isAcceptableBond(
        BondType bondType,
        address token,
        uint256 amount
    ) external view returns (bool) {
        return _isAcceptableBond(bondType, token, amount);
    }

    /// @inheritdoc ITruthEngine
    function nextTocId() external view returns (uint256) {
        return _nextTocId;
    }

    /// @inheritdoc ITruthEngine
    function defaultDisputeWindow() external view returns (uint256) {
        return _defaultDisputeWindow;
    }

    /// @inheritdoc ITruthEngine
    function getCreationFee(
        address resolver,
        uint32 templateId
    ) external view returns (uint256 protocolFee, uint256 resolverFee, uint256 total) {
        protocolFee = protocolFeeStandard;
        resolverFee = resolverTemplateFees[resolver][templateId];
        total = protocolFee + resolverFee;
    }

    /// @inheritdoc ITruthEngine
    function getProtocolFees() external view returns (uint256 minimum, uint256 standard) {
        return (protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITruthEngine
    function getTKSharePercent(AccountabilityTier tier) external view returns (uint256) {
        return tkSharePercent[tier];
    }

    /// @inheritdoc ITruthEngine
    function getProtocolBalance(FeeCategory category) external view returns (uint256) {
        return protocolBalances[category];
    }

    /// @inheritdoc ITruthEngine
    function getTKBalance(address tk) external view returns (uint256) {
        return tkBalances[tk];
    }

    /// @inheritdoc ITruthEngine
    function getResolverFeeByToc(uint256 tocId) external view returns (uint256) {
        return resolverFeeByToc[tocId];
    }

    // ============ Flexible Dispute Window View Functions ============

    /// @inheritdoc ITruthEngine
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

    /// @inheritdoc ITruthEngine
    function isContested(uint256 tocId) external view returns (bool) {
        DisputeInfo storage disputeInfo = _disputes[tocId];
        return disputeInfo.phase == DisputePhase.POST_RESOLUTION && disputeInfo.disputer != address(0);
    }

    /// @inheritdoc ITruthEngine
    function hasCorrectedResult(uint256 tocId) external view returns (bool) {
        return _hasCorrectedResult[tocId];
    }

    // ============ TruthKeeper View Functions ============

    /// @inheritdoc ITruthEngine
    function isWhitelistedTruthKeeper(address tk) external view returns (bool) {
        return _whitelistedTruthKeepers.contains(tk);
    }

    /// @inheritdoc ITruthEngine
    function canDispute(uint256 tocId) external view returns (bool) {
        TOC storage toc = _tocs[tocId];
        if (toc.state == TOCState.RESOLVING && block.timestamp < toc.disputeDeadline) return true;
        if (toc.state == TOCState.RESOLVED && toc.postDisputeDeadline > 0 && block.timestamp < toc.postDisputeDeadline) return true;
        return false;
    }

    /// @inheritdoc ITruthEngine
    function canFinalize(uint256 tocId) external view returns (bool) {
        TOC storage toc = _tocs[tocId];
        return toc.state == TOCState.RESOLVING && block.timestamp >= toc.disputeDeadline && _disputes[tocId].disputer == address(0);
    }

    /// @inheritdoc ITruthEngine
    function getEscalationInfo(uint256 tocId) external view returns (EscalationInfo memory) {
        return _escalations[tocId];
    }

    // ============ Resolver Fee Functions ============

    /// @inheritdoc ITruthEngine
    function setResolverFee(uint32 templateId, uint256 amount) external nonReentrant {
        if (_resolverConfigs[msg.sender].trust == ResolverTrust.NONE) revert NotRegistered();
        resolverTemplateFees[msg.sender][templateId] = amount;
        emit ResolverFeeSet(msg.sender, templateId, amount);
    }

    /// @inheritdoc ITruthEngine
    function getResolverFee(address resolver, uint32 templateId) external view returns (uint256) {
        return resolverTemplateFees[resolver][templateId];
    }

    // ============ Fee Withdrawal Functions ============

    /// @inheritdoc ITruthEngine
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

    /// @inheritdoc ITruthEngine
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

    /// @inheritdoc ITruthEngine
    function withdrawTKFees() external nonReentrant {
        uint256 amount = tkBalances[msg.sender];
        if (amount == 0) revert NoFeesToWithdraw();

        tkBalances[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TKFeesWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc ITruthEngine
    function claimResolverFee(uint256 tocId) external nonReentrant {
        TOC storage toc = _tocs[tocId];
        if (msg.sender != toc.resolver) revert Unauthorized();

        uint256 amount = resolverFeeByToc[tocId];
        if (amount == 0) revert NoFeesToWithdraw();

        resolverFeeByToc[tocId] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ResolverFeeClaimed(msg.sender, tocId, amount);
    }

    /// @inheritdoc ITruthEngine
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

    /// @inheritdoc ITruthEngine
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

    /// @inheritdoc ITruthEngine
    function getExtensiveResultStrict(uint256 tocId) external view returns (ExtensiveResult memory result) {
        TOC storage toc = _tocs[tocId];

        // Must be fully finalized
        if (toc.state != TOCState.RESOLVED) revert NotFinalized();

        // Post-resolution dispute window must have passed
        if (toc.postDisputeDeadline > 0 && block.timestamp < toc.postDisputeDeadline) revert NotFinalized();

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
        if (msg.value < totalFee) revert Insufficient();

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

    /// @notice Check if a bond is acceptable for given type
    function _isAcceptableBond(
        BondType bondType,
        address token,
        uint256 amount
    ) internal view returns (bool) {
        BondRequirement[] storage bonds = _acceptableBonds[bondType];
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i].token == token && amount >= bonds[i].minAmount) {
                return true;
            }
        }
        return false;
    }

    /// @notice Transfer bond into the contract
    function _transferBondIn(address token, uint256 amount) internal {
        if (token == address(0)) {
            // Native token
            if (msg.value < amount) revert Insufficient();
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
            if (!success) revert TransferFailed();
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
