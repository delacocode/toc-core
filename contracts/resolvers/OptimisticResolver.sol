// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "../Popregistry/IPopResolver.sol";
import "../Popregistry/IPOPRegistry.sol";
import "../Popregistry/POPTypes.sol";
import "../libraries/POPResultCodec.sol";

/// @title OptimisticResolver
/// @notice Resolver for human-judgment questions using optimistic proposal model
/// @dev Implements 3 templates:
///   - Template 0: Arbitrary Question - Free-form YES/NO questions
///   - Template 1: Sports Outcome - Structured sports event questions
///   - Template 2: Event Occurrence - Did a specific event occur?
contract OptimisticResolver is IPopResolver {
    // ============ Constants ============

    uint32 public constant TEMPLATE_ARBITRARY = 0;
    uint32 public constant TEMPLATE_SPORTS = 1;
    uint32 public constant TEMPLATE_EVENT = 2;
    uint32 public constant TEMPLATE_COUNT = 3;

    /// @notice Maximum question/description length (8KB, matching UMA)
    uint256 public constant MAX_TEXT_LENGTH = 8192;

    // ============ Immutables ============

    IPOPRegistry public immutable registry;

    // ============ Enums ============

    /// @notice Types of sports questions
    enum SportQuestionType {
        WINNER,      // Which team wins?
        SPREAD,      // Does home team cover spread?
        OVER_UNDER   // Is total score over/under line?
    }

    // ============ Structs ============

    /// @notice Core question data stored for each POP
    struct QuestionData {
        uint32 templateId;
        address creator;
        uint256 createdAt;
        bytes payload;
    }

    /// @notice Payload for Template 0: Arbitrary Question
    struct ArbitraryPayload {
        string question;
        string description;
        string resolutionSource;
        uint256 resolutionTime;
    }

    /// @notice Payload for Template 1: Sports Outcome
    struct SportsPayload {
        string league;
        string homeTeam;
        string awayTeam;
        uint256 gameTime;
        SportQuestionType questionType;
        int256 line; // For spread/over-under (scaled 1e18)
    }

    /// @notice Payload for Template 2: Event Occurrence
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

    /// @notice Question data for each POP
    mapping(uint256 => QuestionData) private _questions;

    /// @notice Clarifications for each POP (append-only)
    mapping(uint256 => string[]) private _clarifications;

    // ============ Events ============

    event QuestionCreated(
        uint256 indexed popId,
        uint32 indexed templateId,
        address indexed creator,
        string questionPreview
    );

    event ClarificationAdded(
        uint256 indexed popId,
        address indexed creator,
        string clarification
    );

    // ============ Errors ============

    error InvalidTemplate(uint32 templateId);
    error InvalidPayload();
    error OnlyRegistry();
    error OnlyCreator(address caller, address creator);
    error CannotClarifyAfterResolution(POPState state);
    error TextTooLong(uint256 length, uint256 max);
    error ResolutionTimeInPast(uint256 resolutionTime, uint256 current);
    error PopNotManaged(uint256 popId);
    error EmptyQuestion();

    // ============ Modifiers ============

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) {
            revert OnlyRegistry();
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _registry) {
        registry = IPOPRegistry(_registry);
    }

    // ============ IPopResolver Implementation ============

    /// @inheritdoc IPopResolver
    function isPopManaged(uint256 popId) external view returns (bool) {
        return _questions[popId].createdAt != 0;
    }

    /// @inheritdoc IPopResolver
    function onPopCreated(
        uint256 popId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (POPState initialState) {
        if (templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }

        // Validate and extract question preview based on template
        string memory questionPreview = _validateAndGetPreview(templateId, payload);

        // Store question data
        _questions[popId] = QuestionData({
            templateId: templateId,
            creator: tx.origin, // Original caller, not registry
            createdAt: block.timestamp,
            payload: payload
        });

        emit QuestionCreated(popId, templateId, tx.origin, questionPreview);

        // All optimistic questions start ACTIVE (no approval needed)
        return POPState.ACTIVE;
    }

    /// @inheritdoc IPopResolver
    function resolvePop(
        uint256 popId,
        address, // caller - not used for access control in optimistic model
        bytes calldata answerPayload
    ) external onlyRegistry returns (bytes memory result) {
        QuestionData storage q = _questions[popId];
        if (q.createdAt == 0) {
            revert PopNotManaged(popId);
        }

        // Decode answer payload
        AnswerPayload memory answer = abi.decode(answerPayload, (AnswerPayload));

        // All templates return boolean
        return POPResultCodec.encodeBoolean(answer.answer);
    }

    /// @inheritdoc IPopResolver
    function getPopDetails(
        uint256 popId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        QuestionData storage q = _questions[popId];
        return (q.templateId, q.payload);
    }

    /// @inheritdoc IPopResolver
    function getPopQuestion(uint256 popId) external view returns (string memory question) {
        QuestionData storage q = _questions[popId];
        if (q.createdAt == 0) {
            return "Unknown POP";
        }

        if (q.templateId == TEMPLATE_ARBITRARY) {
            return _formatArbitraryQuestion(popId, q);
        } else if (q.templateId == TEMPLATE_SPORTS) {
            return _formatSportsQuestion(popId, q);
        } else if (q.templateId == TEMPLATE_EVENT) {
            return _formatEventQuestion(popId, q);
        }

        return "Unknown template";
    }

    /// @inheritdoc IPopResolver
    function getTemplateCount() external pure returns (uint32 count) {
        return TEMPLATE_COUNT;
    }

    /// @inheritdoc IPopResolver
    function isValidTemplate(uint32 templateId) external pure returns (bool) {
        return templateId < TEMPLATE_COUNT;
    }

    /// @inheritdoc IPopResolver
    function getTemplateAnswerType(uint32) external pure returns (AnswerType) {
        // All optimistic templates return boolean (YES/NO)
        return AnswerType.BOOLEAN;
    }

    // ============ Clarification Functions ============

    /// @notice Add a clarification to an existing question
    /// @dev Only the original creator can add clarifications, and only before resolution
    /// @param popId The POP identifier
    /// @param clarification The clarification text to add
    function addClarification(uint256 popId, string calldata clarification) external {
        QuestionData storage q = _questions[popId];
        if (q.createdAt == 0) {
            revert PopNotManaged(popId);
        }

        // Only creator can add clarifications
        if (msg.sender != q.creator) {
            revert OnlyCreator(msg.sender, q.creator);
        }

        // Check text length
        if (bytes(clarification).length > MAX_TEXT_LENGTH) {
            revert TextTooLong(bytes(clarification).length, MAX_TEXT_LENGTH);
        }

        // Can only clarify while POP is ACTIVE or PENDING
        POP memory pop = registry.getPOP(popId);
        if (pop.state != POPState.ACTIVE && pop.state != POPState.PENDING) {
            revert CannotClarifyAfterResolution(pop.state);
        }

        // Add timestamped clarification
        string memory timestamped = string(abi.encodePacked(
            "[",
            _formatTimestamp(block.timestamp),
            "] ",
            clarification
        ));
        _clarifications[popId].push(timestamped);

        emit ClarificationAdded(popId, msg.sender, clarification);
    }

    /// @notice Get all clarifications for a POP
    /// @param popId The POP identifier
    /// @return clarifications Array of clarification strings
    function getClarifications(uint256 popId) external view returns (string[] memory) {
        return _clarifications[popId];
    }

    /// @notice Get question data for a POP
    /// @param popId The POP identifier
    /// @return templateId The template used
    /// @return creator The question creator
    /// @return createdAt Creation timestamp
    function getQuestionData(uint256 popId) external view returns (
        uint32 templateId,
        address creator,
        uint256 createdAt
    ) {
        QuestionData storage q = _questions[popId];
        return (q.templateId, q.creator, q.createdAt);
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
        uint256 popId,
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
        result = _appendClarifications(popId, result);

        return result;
    }

    function _formatSportsQuestion(
        uint256 popId,
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

        result = _appendClarifications(popId, result);

        return result;
    }

    function _formatEventQuestion(
        uint256 popId,
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

        result = _appendClarifications(popId, result);

        return result;
    }

    function _appendClarifications(
        uint256 popId,
        string memory base
    ) internal view returns (string memory) {
        string[] storage clarifications = _clarifications[popId];

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
