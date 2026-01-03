// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "../TruthEngine/ITOCResolver.sol";
import "../TruthEngine/ITruthEngine.sol";
import "../TruthEngine/TOCTypes.sol";
import "../libraries/TOCResultCodec.sol";
import "./IClarifiable.sol";

/// @title OptimisticResolver
/// @notice Resolver for human-judgment questions using optimistic proposal model
/// @dev Implements 3 templates:
///   - Template 0: NONE (reserved)
///   - Template 1: Arbitrary Question - Free-form YES/NO questions
///   - Template 2: Sports Outcome - Structured sports event questions
///   - Template 3: Event Occurrence - Did a specific event occur?
contract OptimisticResolver is ITOCResolver, IClarifiable {
    // ============ Constants ============

    uint32 public constant TEMPLATE_NONE = 0;
    uint32 public constant TEMPLATE_ARBITRARY = 1;
    uint32 public constant TEMPLATE_SPORTS = 2;
    uint32 public constant TEMPLATE_EVENT = 3;
    uint32 public constant TEMPLATE_COUNT = 4;

    /// @notice Maximum question/description length (8KB, matching UMA)
    uint256 public constant MAX_TEXT_LENGTH = 8192;

    // ============ Immutables ============

    ITruthEngine public immutable registry;
    address public immutable owner;

    // ============ Enums ============

    /// @notice Types of sports questions
    enum SportQuestionType {
        WINNER,      // Which team wins?
        SPREAD,      // Does home team cover spread?
        OVER_UNDER   // Is total score over/under line?
    }

    // ============ Structs ============

    /// @notice Core question data stored for each TOC
    /// @dev Creator is read from registry.getTOC(tocId).creator
    struct QuestionData {
        uint32 templateId;
        uint256 createdAt;
        bytes payload;
    }

    /// @notice Payload for Template 1: Arbitrary Question
    struct ArbitraryPayload {
        string question;
        string description;
        string resolutionSource;
        uint256 resolutionTime;
    }

    /// @notice Payload for Template 2: Sports Outcome
    struct SportsPayload {
        string league;
        string homeTeam;
        string awayTeam;
        uint256 gameTime;
        SportQuestionType questionType;
        int256 line; // For spread/over-under (scaled 1e18)
    }

    /// @notice Payload for Template 3: Event Occurrence
    struct EventPayload {
        string eventDescription;
        string verificationSource;
        uint256 deadline;
    }

    /// @notice Answer payload for proposals
    struct AnswerPayload {
        bool answer;
        string justification;
    }

    // ============ Storage ============

    /// @notice Question data for each TOC
    mapping(uint256 => QuestionData) private _questions;

    /// @notice Accepted clarifications for each TOC
    mapping(uint256 => string[]) private _clarifications;

    /// @notice Pending clarifications for each TOC
    mapping(uint256 => mapping(uint256 => string)) private _pendingClarifications;

    /// @notice Status of each clarification (true = pending, false = processed)
    mapping(uint256 => mapping(uint256 => bool)) private _isPending;

    /// @notice Next clarification ID for each TOC
    mapping(uint256 => uint256) private _nextClarificationId;

    // ============ Events ============

    event QuestionCreated(
        uint256 indexed tocId,
        uint32 indexed templateId,
        address indexed creator,
        string questionPreview
    );

    event ResolutionProposed(
        uint256 indexed tocId,
        address indexed proposer,
        bool answer,
        string justification
    );

    // Note: ClarificationRequested, ClarificationAccepted, ClarificationRejected
    // are inherited from IClarifiable

    // ============ Errors ============

    error InvalidTemplate(uint32 templateId);
    error InvalidPayload();
    error OnlyRegistry();
    error OnlyCreator(address caller, address creator);
    error CannotClarifyAfterResolution(TOCState state);
    error TextTooLong(uint256 length, uint256 max);
    error ResolutionTimeInPast(uint256 resolutionTime, uint256 current);
    error TocNotManaged(uint256 tocId);
    error EmptyQuestion();
    error ClarificationNotPending(uint256 tocId, uint256 clarificationId);
    error NotOwner(address caller);

    // ============ Modifiers ============

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) {
            revert OnlyRegistry();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner(msg.sender);
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _registry) {
        registry = ITruthEngine(_registry);
        owner = msg.sender;
    }

    // ============ ITOCResolver Implementation ============

    /// @inheritdoc ITOCResolver
    function isTocManaged(uint256 tocId) external view returns (bool) {
        return _questions[tocId].createdAt != 0;
    }

    /// @inheritdoc ITOCResolver
    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload,
        address creator
    ) external onlyRegistry returns (TOCState initialState) {
        if (templateId == TEMPLATE_NONE || templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }

        // Validate and extract question preview based on template
        string memory questionPreview = _validateAndGetPreview(templateId, payload);

        // Store question data (creator is stored in registry)
        _questions[tocId] = QuestionData({
            templateId: templateId,
            createdAt: block.timestamp,
            payload: payload
        });

        emit QuestionCreated(tocId, templateId, creator, questionPreview);

        // All optimistic questions start ACTIVE (no approval needed)
        return TOCState.ACTIVE;
    }

    /// @inheritdoc ITOCResolver
    function resolveToc(
        uint256 tocId,
        address caller,
        bytes calldata answerPayload
    ) external onlyRegistry returns (bytes memory result) {
        QuestionData storage q = _questions[tocId];
        if (q.createdAt == 0) {
            revert TocNotManaged(tocId);
        }

        // Decode answer payload
        AnswerPayload memory answer = abi.decode(answerPayload, (AnswerPayload));

        // Emit event for audit trail
        emit ResolutionProposed(tocId, caller, answer.answer, answer.justification);

        // All templates return boolean
        return TOCResultCodec.encodeBoolean(answer.answer);
    }

    /// @inheritdoc ITOCResolver
    function getTocDetails(
        uint256 tocId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        QuestionData storage q = _questions[tocId];
        return (q.templateId, q.payload);
    }

    /// @inheritdoc ITOCResolver
    function getTocQuestion(uint256 tocId) external view returns (string memory question) {
        QuestionData storage q = _questions[tocId];
        if (q.createdAt == 0) {
            return "Unknown TOC";
        }

        if (q.templateId == TEMPLATE_ARBITRARY) {
            return _formatArbitraryQuestion(tocId, q);
        } else if (q.templateId == TEMPLATE_SPORTS) {
            return _formatSportsQuestion(tocId, q);
        } else if (q.templateId == TEMPLATE_EVENT) {
            return _formatEventQuestion(tocId, q);
        }

        return "Unknown template";
    }

    /// @inheritdoc ITOCResolver
    function getTemplateCount() external pure returns (uint32 count) {
        return TEMPLATE_COUNT;
    }

    /// @inheritdoc ITOCResolver
    function isValidTemplate(uint32 templateId) external pure returns (bool) {
        return templateId > TEMPLATE_NONE && templateId < TEMPLATE_COUNT;
    }

    /// @inheritdoc ITOCResolver
    function getTemplateAnswerType(uint32) external pure returns (AnswerType) {
        // All optimistic templates return boolean (YES/NO)
        return AnswerType.BOOLEAN;
    }

    // ============ IClarifiable Implementation ============

    /// @inheritdoc IClarifiable
    function requestClarification(
        uint256 tocId,
        string calldata text
    ) external returns (ClarificationResponse response, uint256 clarificationId) {
        QuestionData storage q = _questions[tocId];
        if (q.createdAt == 0) {
            revert TocNotManaged(tocId);
        }

        // Get TOC from registry (creator is stored there)
        TOC memory toc = registry.getTOC(tocId);

        // Only creator can request clarifications
        if (msg.sender != toc.creator) {
            revert OnlyCreator(msg.sender, toc.creator);
        }

        // Check text length
        if (bytes(text).length > MAX_TEXT_LENGTH) {
            revert TextTooLong(bytes(text).length, MAX_TEXT_LENGTH);
        }

        // Can only clarify while TOC is ACTIVE or PENDING
        if (toc.state != TOCState.ACTIVE && toc.state != TOCState.PENDING) {
            revert CannotClarifyAfterResolution(toc.state);
        }

        // Assign clarification ID
        clarificationId = _nextClarificationId[tocId]++;

        emit ClarificationRequested(tocId, msg.sender, clarificationId, text);

        // OptimisticResolver auto-accepts all clarifications
        // Other resolvers can implement different logic (PENDING, REJECT)
        response = ClarificationResponse.ACCEPT;

        // Add timestamped clarification immediately
        string memory timestamped = string(abi.encodePacked(
            "[",
            _formatTimestamp(block.timestamp),
            "] ",
            text
        ));
        _clarifications[tocId].push(timestamped);

        emit ClarificationAccepted(tocId, clarificationId);
    }

    /// @inheritdoc IClarifiable
    function approveClarification(uint256 tocId, uint256 clarificationId) external onlyOwner {
        if (!_isPending[tocId][clarificationId]) {
            revert ClarificationNotPending(tocId, clarificationId);
        }

        string memory text = _pendingClarifications[tocId][clarificationId];

        // Add timestamped clarification
        string memory timestamped = string(abi.encodePacked(
            "[",
            _formatTimestamp(block.timestamp),
            "] ",
            text
        ));
        _clarifications[tocId].push(timestamped);

        // Clear pending
        _isPending[tocId][clarificationId] = false;
        delete _pendingClarifications[tocId][clarificationId];

        emit ClarificationAccepted(tocId, clarificationId);
    }

    /// @inheritdoc IClarifiable
    function rejectClarification(uint256 tocId, uint256 clarificationId) external onlyOwner {
        if (!_isPending[tocId][clarificationId]) {
            revert ClarificationNotPending(tocId, clarificationId);
        }

        // Clear pending
        _isPending[tocId][clarificationId] = false;
        delete _pendingClarifications[tocId][clarificationId];

        emit ClarificationRejected(tocId, clarificationId);
    }

    /// @inheritdoc IClarifiable
    function getClarifications(uint256 tocId) external view returns (string[] memory) {
        return _clarifications[tocId];
    }

    /// @inheritdoc IClarifiable
    function getPendingClarifications(
        uint256 tocId
    ) external view returns (uint256[] memory ids, string[] memory texts) {
        // Count pending clarifications
        uint256 count = 0;
        uint256 nextId = _nextClarificationId[tocId];
        for (uint256 i = 0; i < nextId; i++) {
            if (_isPending[tocId][i]) {
                count++;
            }
        }

        // Allocate arrays
        ids = new uint256[](count);
        texts = new string[](count);

        // Fill arrays
        uint256 index = 0;
        for (uint256 i = 0; i < nextId; i++) {
            if (_isPending[tocId][i]) {
                ids[index] = i;
                texts[index] = _pendingClarifications[tocId][i];
                index++;
            }
        }
    }

    // ============ Legacy Compatibility ============

    /// @notice Legacy function for backwards compatibility
    /// @dev Calls requestClarification internally
    function addClarification(uint256 tocId, string calldata clarification) external {
        QuestionData storage q = _questions[tocId];
        if (q.createdAt == 0) {
            revert TocNotManaged(tocId);
        }

        // Get TOC from registry (creator is stored there)
        TOC memory toc = registry.getTOC(tocId);

        if (msg.sender != toc.creator) {
            revert OnlyCreator(msg.sender, toc.creator);
        }
        if (bytes(clarification).length > MAX_TEXT_LENGTH) {
            revert TextTooLong(bytes(clarification).length, MAX_TEXT_LENGTH);
        }
        if (toc.state != TOCState.ACTIVE && toc.state != TOCState.PENDING) {
            revert CannotClarifyAfterResolution(toc.state);
        }

        uint256 clarificationId = _nextClarificationId[tocId]++;
        emit ClarificationRequested(tocId, msg.sender, clarificationId, clarification);

        // Auto-accept
        string memory timestamped = string(abi.encodePacked(
            "[",
            _formatTimestamp(block.timestamp),
            "] ",
            clarification
        ));
        _clarifications[tocId].push(timestamped);
        emit ClarificationAccepted(tocId, clarificationId);
    }

    /// @notice Get question data for a TOC
    /// @param tocId The TOC identifier
    /// @return templateId The template used
    /// @return creator The question creator (from registry)
    /// @return createdAt Creation timestamp
    function getQuestionData(uint256 tocId) external view returns (
        uint32 templateId,
        address creator,
        uint256 createdAt
    ) {
        QuestionData storage q = _questions[tocId];
        TOC memory toc = registry.getTOC(tocId);
        return (q.templateId, toc.creator, q.createdAt);
    }

    // ============ Internal Validation ============

    function _validateAndGetPreview(
        uint32 templateId,
        bytes calldata payload
    ) internal view returns (string memory preview) {
        if (templateId == TEMPLATE_ARBITRARY) {
            ArbitraryPayload memory p = abi.decode(payload, (ArbitraryPayload));

            if (bytes(p.question).length == 0) revert EmptyQuestion();
            if (bytes(p.question).length > MAX_TEXT_LENGTH) {
                revert TextTooLong(bytes(p.question).length, MAX_TEXT_LENGTH);
            }
            if (bytes(p.description).length > MAX_TEXT_LENGTH) {
                revert TextTooLong(bytes(p.description).length, MAX_TEXT_LENGTH);
            }
            if (p.resolutionTime <= block.timestamp) {
                revert ResolutionTimeInPast(p.resolutionTime, block.timestamp);
            }

            return p.question;

        } else if (templateId == TEMPLATE_SPORTS) {
            SportsPayload memory p = abi.decode(payload, (SportsPayload));

            if (bytes(p.homeTeam).length == 0 || bytes(p.awayTeam).length == 0) {
                revert EmptyQuestion();
            }
            if (p.gameTime <= block.timestamp) {
                revert ResolutionTimeInPast(p.gameTime, block.timestamp);
            }

            return string(abi.encodePacked(p.league, ": ", p.homeTeam, " vs ", p.awayTeam));

        } else if (templateId == TEMPLATE_EVENT) {
            EventPayload memory p = abi.decode(payload, (EventPayload));

            if (bytes(p.eventDescription).length == 0) revert EmptyQuestion();
            if (bytes(p.eventDescription).length > MAX_TEXT_LENGTH) {
                revert TextTooLong(bytes(p.eventDescription).length, MAX_TEXT_LENGTH);
            }
            if (p.deadline <= block.timestamp) {
                revert ResolutionTimeInPast(p.deadline, block.timestamp);
            }

            return p.eventDescription;
        }

        revert InvalidTemplate(templateId);
    }

    // ============ Internal Formatting ============

    function _formatArbitraryQuestion(
        uint256 tocId,
        QuestionData storage q
    ) internal view returns (string memory) {
        ArbitraryPayload memory p = abi.decode(q.payload, (ArbitraryPayload));

        string memory result = string(abi.encodePacked(
            "Q: ", p.question, "\n\n",
            "Description: ", p.description, "\n\n",
            "Resolution Source: ", p.resolutionSource, "\n\n",
            "Resolution Time: ", _formatTimestamp(p.resolutionTime)
        ));

        // Add clarifications if any
        result = _appendClarifications(tocId, result);

        return result;
    }

    function _formatSportsQuestion(
        uint256 tocId,
        QuestionData storage q
    ) internal view returns (string memory) {
        SportsPayload memory p = abi.decode(q.payload, (SportsPayload));

        string memory questionType;
        string memory details = "";

        if (p.questionType == SportQuestionType.WINNER) {
            questionType = "WINNER";
            details = "Resolves YES if home team wins, NO if away team wins.";
        } else if (p.questionType == SportQuestionType.SPREAD) {
            questionType = "SPREAD";
            details = string(abi.encodePacked(
                "Resolves YES if home team covers spread of ",
                _int256ToString(p.line / 1e16), // Show as decimal
                "."
            ));
        } else {
            questionType = "OVER_UNDER";
            details = string(abi.encodePacked(
                "Resolves YES if total score is over ",
                _int256ToString(p.line / 1e16),
                "."
            ));
        }

        string memory result = string(abi.encodePacked(
            "Q: ", p.league, " - ", p.homeTeam, " vs ", p.awayTeam, "\n\n",
            "Game Time: ", _formatTimestamp(p.gameTime), "\n\n",
            "Question Type: ", questionType, "\n\n",
            "Resolution: ", details, "\n",
            "Overtime counts. If game is cancelled, resolves via dispute."
        ));

        result = _appendClarifications(tocId, result);

        return result;
    }

    function _formatEventQuestion(
        uint256 tocId,
        QuestionData storage q
    ) internal view returns (string memory) {
        EventPayload memory p = abi.decode(q.payload, (EventPayload));

        string memory result = string(abi.encodePacked(
            "Q: Will the following event occur?\n\n",
            "Event: ", p.eventDescription, "\n\n",
            "Verification Source: ", p.verificationSource, "\n\n",
            "Deadline: ", _formatTimestamp(p.deadline), "\n\n",
            "Resolves YES if event occurs by deadline, NO otherwise."
        ));

        result = _appendClarifications(tocId, result);

        return result;
    }

    function _appendClarifications(
        uint256 tocId,
        string memory base
    ) internal view returns (string memory) {
        string[] storage clarifications = _clarifications[tocId];

        if (clarifications.length == 0) {
            return base;
        }

        string memory result = string(abi.encodePacked(base, "\n\nClarifications:"));

        for (uint256 i = 0; i < clarifications.length; i++) {
            result = string(abi.encodePacked(result, "\n- ", clarifications[i]));
        }

        return result;
    }

    // ============ String Helpers ============

    function _formatTimestamp(uint256 timestamp) internal pure returns (string memory) {
        // Simple format: just return the unix timestamp for now
        // Could be enhanced with proper date formatting
        return string(abi.encodePacked("timestamp:", _uint256ToString(timestamp)));
    }

    function _int256ToString(int256 value) internal pure returns (string memory) {
        if (value < 0) {
            return string(abi.encodePacked("-", _uint256ToString(uint256(-value))));
        }
        return _uint256ToString(uint256(value));
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
