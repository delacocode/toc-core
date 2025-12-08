// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../Popregistry/POPRegistry.sol";
import "../Popregistry/POPTypes.sol";
import "../resolvers/OptimisticResolver.sol";

/// @title OptimisticResolverTest
/// @notice Tests for OptimisticResolver contract
contract OptimisticResolverTest is Test {
    POPRegistry registry;
    OptimisticResolver resolver;

    address owner;
    address user1;
    address user2;
    address truthKeeper;
    address creator;

    uint256 constant MIN_RESOLUTION_BOND = 0.1 ether;
    uint256 constant MIN_DISPUTE_BOND = 0.05 ether;
    uint256 constant DEFAULT_DISPUTE_WINDOW = 24 hours;
    uint256 constant DEFAULT_TK_WINDOW = 24 hours;
    uint256 constant DEFAULT_ESCALATION_WINDOW = 48 hours;
    uint256 constant DEFAULT_POST_RESOLUTION_WINDOW = 24 hours;

    // ============ Setup ============

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        truthKeeper = address(0x4);
        creator = address(0x5);

        // Fund creator
        vm.deal(creator, 10 ether);

        // Deploy registry
        registry = new POPRegistry();

        // Deploy optimistic resolver
        resolver = new OptimisticResolver(address(registry));

        // Configure acceptable bonds
        registry.addAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(0), MIN_DISPUTE_BOND);

        // Whitelist TruthKeeper
        registry.addWhitelistedTruthKeeper(truthKeeper);

        // Register resolver
        registry.registerResolver(address(resolver));
    }

    // ============ Template 0: Arbitrary Question Tests ============

    function test_CreateArbitraryQuestion() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will Bitcoin reach $150,000 by end of 2025?",
            description: "This market resolves YES if BTC reaches $150k USD at any point before deadline.",
            resolutionSource: "CoinGecko, CoinMarketCap",
            resolutionTime: block.timestamp + 365 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0, // TEMPLATE_ARBITRARY
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        require(popId == 1, "First POP should have ID 1");

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.ACTIVE, "State should be ACTIVE");
        require(pop.answerType == AnswerType.BOOLEAN, "Answer type should be BOOLEAN");
    }

    function test_GetArbitraryQuestion() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will ETH flip BTC?",
            description: "Resolves YES if ETH market cap exceeds BTC market cap.",
            resolutionSource: "CoinMarketCap",
            resolutionTime: block.timestamp + 30 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        string memory question = registry.getPopQuestion(popId);
        require(bytes(question).length > 0, "Question should not be empty");
        // Check it contains our question text
        require(_contains(question, "Will ETH flip BTC?"), "Should contain question text");
    }

    function test_ResolveArbitraryQuestionYes() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test question?",
            description: "Test description",
            resolutionSource: "Test source",
            resolutionTime: block.timestamp + 1 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            0, // No dispute window for simplicity
            0,
            0,
            0,
            truthKeeper
        );

        // Create answer payload
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "The event occurred as expected"
        });

        // Resolve
        registry.resolvePOP(popId, address(0), 0, abi.encode(answer));

        // Check result
        bool result = registry.getBooleanResult(popId);
        require(result == true, "Result should be true");
    }

    function test_ResolveArbitraryQuestionNo() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test question?",
            description: "Test description",
            resolutionSource: "Test source",
            resolutionTime: block.timestamp + 1 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            0, 0, 0, 0,
            truthKeeper
        );

        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: false,
            justification: "The event did not occur"
        });

        registry.resolvePOP(popId, address(0), 0, abi.encode(answer));

        bool result = registry.getBooleanResult(popId);
        require(result == false, "Result should be false");
    }

    function test_RevertEmptyQuestion() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "", // Empty!
            description: "Test description",
            resolutionSource: "Test source",
            resolutionTime: block.timestamp + 1 days
        });

        bool reverted = false;
        try registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on empty question");
    }

    function test_RevertResolutionTimeInPast() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test question?",
            description: "Test description",
            resolutionSource: "Test source",
            resolutionTime: block.timestamp - 1 // In the past!
        });

        bool reverted = false;
        try registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when resolution time is in past");
    }

    // ============ Template 1: Sports Tests ============

    function test_CreateSportsQuestion() public {
        OptimisticResolver.SportsPayload memory payload = OptimisticResolver.SportsPayload({
            league: "NFL",
            homeTeam: "Kansas City Chiefs",
            awayTeam: "San Francisco 49ers",
            gameTime: block.timestamp + 7 days,
            questionType: OptimisticResolver.SportQuestionType.WINNER,
            line: 0
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            1, // TEMPLATE_SPORTS
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.ACTIVE, "State should be ACTIVE");

        string memory question = registry.getPopQuestion(popId);
        require(_contains(question, "Kansas City Chiefs"), "Should contain home team");
        require(_contains(question, "San Francisco 49ers"), "Should contain away team");
        require(_contains(question, "NFL"), "Should contain league");
    }

    function test_CreateSportsSpreadQuestion() public {
        OptimisticResolver.SportsPayload memory payload = OptimisticResolver.SportsPayload({
            league: "NBA",
            homeTeam: "Lakers",
            awayTeam: "Celtics",
            gameTime: block.timestamp + 2 days,
            questionType: OptimisticResolver.SportQuestionType.SPREAD,
            line: -35e17 // -3.5 points
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            1,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        string memory question = registry.getPopQuestion(popId);
        require(_contains(question, "SPREAD"), "Should mention SPREAD");
    }

    function test_ResolveSportsQuestion() public {
        OptimisticResolver.SportsPayload memory payload = OptimisticResolver.SportsPayload({
            league: "NFL",
            homeTeam: "Chiefs",
            awayTeam: "49ers",
            gameTime: block.timestamp + 7 days,
            questionType: OptimisticResolver.SportQuestionType.WINNER,
            line: 0
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            1,
            abi.encode(payload),
            0, 0, 0, 0, // No dispute windows
            truthKeeper
        );

        // Chiefs win!
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "Chiefs won 25-22 in OT"
        });

        registry.resolvePOP(popId, address(0), 0, abi.encode(answer));

        bool result = registry.getBooleanResult(popId);
        require(result == true, "Result should be true (home team won)");
    }

    // ============ Template 2: Event Tests ============

    function test_CreateEventQuestion() public {
        OptimisticResolver.EventPayload memory payload = OptimisticResolver.EventPayload({
            eventDescription: "Fed announces interest rate cut of at least 25 basis points",
            verificationSource: "Federal Reserve official press release",
            deadline: block.timestamp + 30 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            2, // TEMPLATE_EVENT
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.ACTIVE, "State should be ACTIVE");

        string memory question = registry.getPopQuestion(popId);
        require(_contains(question, "Fed announces"), "Should contain event description");
        require(_contains(question, "Federal Reserve"), "Should contain verification source");
    }

    function test_ResolveEventQuestion() public {
        OptimisticResolver.EventPayload memory payload = OptimisticResolver.EventPayload({
            eventDescription: "Company X announces bankruptcy",
            verificationSource: "SEC filings",
            deadline: block.timestamp + 30 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            2,
            abi.encode(payload),
            0, 0, 0, 0,
            truthKeeper
        );

        // Event did NOT occur
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: false,
            justification: "No bankruptcy filing found by deadline"
        });

        registry.resolvePOP(popId, address(0), 0, abi.encode(answer));

        bool result = registry.getBooleanResult(popId);
        require(result == false, "Result should be false");
    }

    // ============ Clarification Tests ============

    function test_AddClarification() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will X happen?",
            description: "Original description",
            resolutionSource: "Source",
            resolutionTime: block.timestamp + 30 days
        });

        // Create POP as creator (prank sets both msg.sender and tx.origin)
        vm.prank(creator, creator);
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Add clarification as creator
        vm.prank(creator);
        resolver.addClarification(popId, "This includes scenario Y but not Z");

        // Get clarifications
        string[] memory clarifications = resolver.getClarifications(popId);
        require(clarifications.length == 1, "Should have 1 clarification");

        // Check question includes clarification
        string memory question = registry.getPopQuestion(popId);
        require(_contains(question, "Clarifications:"), "Should have clarifications section");
    }

    function test_MultipleClarifications() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will X happen?",
            description: "Description",
            resolutionSource: "Source",
            resolutionTime: block.timestamp + 30 days
        });

        // Create POP as creator
        vm.prank(creator, creator);
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Add clarifications as creator
        vm.prank(creator);
        resolver.addClarification(popId, "First clarification");
        vm.prank(creator);
        resolver.addClarification(popId, "Second clarification");
        vm.prank(creator);
        resolver.addClarification(popId, "Third clarification");

        string[] memory clarifications = resolver.getClarifications(popId);
        require(clarifications.length == 3, "Should have 3 clarifications");
    }

    // ============ View Function Tests ============

    function test_GetQuestionData() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test?",
            description: "Desc",
            resolutionSource: "Src",
            resolutionTime: block.timestamp + 1 days
        });

        // Create POP as creator
        vm.prank(creator, creator);
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        (uint32 templateId, address popCreator, uint256 createdAt) = resolver.getQuestionData(popId);
        require(templateId == 0, "Template should be 0");
        require(popCreator == creator, "Creator should be creator address");
        require(createdAt > 0, "CreatedAt should be set");
    }

    function test_GetPopDetails() public {
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test?",
            description: "Desc",
            resolutionSource: "Src",
            resolutionTime: block.timestamp + 1 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        (uint32 templateId, bytes memory creationPayload) = resolver.getPopDetails(popId);
        require(templateId == 0, "Template should be 0");
        require(creationPayload.length > 0, "Payload should not be empty");
    }

    function test_IsPopManaged() public {
        require(!resolver.isPopManaged(999), "Non-existent POP should not be managed");

        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test?",
            description: "Desc",
            resolutionSource: "Src",
            resolutionTime: block.timestamp + 1 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        require(resolver.isPopManaged(popId), "Created POP should be managed");
    }

    function test_TemplateInfo() public {
        require(resolver.getTemplateCount() == 3, "Should have 3 templates");
        require(resolver.isValidTemplate(0), "Template 0 should be valid");
        require(resolver.isValidTemplate(1), "Template 1 should be valid");
        require(resolver.isValidTemplate(2), "Template 2 should be valid");
        require(!resolver.isValidTemplate(3), "Template 3 should be invalid");

        require(resolver.getTemplateAnswerType(0) == AnswerType.BOOLEAN, "All templates return BOOLEAN");
        require(resolver.getTemplateAnswerType(1) == AnswerType.BOOLEAN, "All templates return BOOLEAN");
        require(resolver.getTemplateAnswerType(2) == AnswerType.BOOLEAN, "All templates return BOOLEAN");
    }

    // ============ Integration with Dispute Flow ============

    function test_FullDisputeFlow() public {
        // Create question with a dispute window so we can test pre-resolution dispute
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will candidate X win the election?",
            description: "Resolves YES if X wins majority of electoral votes",
            resolutionSource: "AP, Reuters, major news networks",
            resolutionTime: block.timestamp + 30 days
        });

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW, // Has dispute window
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Propose YES
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "AP called the race"
        });

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(
            popId,
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer)
        );

        // Check state is RESOLVING (waiting for dispute window)
        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVING, "Should be RESOLVING");

        // File pre-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Premature resolution - event hasn't occurred",
            "",
            false, 0, "" // Propose NO
        );

        // Check disputed (pre-resolution goes to DISPUTED_ROUND_1)
        pop = registry.getPOP(popId);
        require(pop.state == POPState.DISPUTED_ROUND_1, "Should be in DISPUTED_ROUND_1 state");
    }

    // ============ Helpers ============

    function _contains(string memory source, string memory search) internal pure returns (bool) {
        bytes memory sourceBytes = bytes(source);
        bytes memory searchBytes = bytes(search);

        if (searchBytes.length > sourceBytes.length) return false;

        for (uint i = 0; i <= sourceBytes.length - searchBytes.length; i++) {
            bool found = true;
            for (uint j = 0; j < searchBytes.length; j++) {
                if (sourceBytes[i + j] != searchBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    receive() external payable {}
}
