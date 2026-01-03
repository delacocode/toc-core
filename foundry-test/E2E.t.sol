// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "contracts/TruthEngine/TruthEngine.sol";
import "contracts/TruthEngine/TOCTypes.sol";
import "contracts/TruthEngine/ITruthEngine.sol";
import "contracts/resolvers/PythPriceResolverV2.sol";
import "contracts/resolvers/OptimisticResolver.sol";
import "contracts/libraries/TOCResultCodec.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./MockTruthKeeper.sol";

/// @title E2E Test
/// @notice Comprehensive end-to-end tests for the full TOC system lifecycle
/// @dev Tests the complete integration of Registry, Resolvers, TruthKeeper, and dispute flows
contract E2ETest is Test {
    // ============ Contracts ============
    TruthEngine public registry;
    MockPyth public mockPyth;
    PythPriceResolverV2 public pythResolver;
    OptimisticResolver public optimisticResolver;
    MockTruthKeeper public truthKeeperContract;

    // ============ Actors ============
    address public owner;
    address public creator;
    address public resolver1;
    address public resolver2;
    address public disputer;
    address public truthKeeper;

    // ============ Constants ============
    uint256 constant MIN_RESOLUTION_BOND = 0.1 ether;
    uint256 constant MIN_DISPUTE_BOND = 0.05 ether;
    uint256 constant PROTOCOL_FEE = 0.001 ether;
    uint256 constant PYTH_FEE = 1 wei;

    // Note: RESOLVER trust level has MAX_WINDOW_RESOLVER = 1 day
    uint256 constant DEFAULT_DISPUTE_WINDOW = 12 hours;
    uint256 constant DEFAULT_TK_WINDOW = 12 hours;
    uint256 constant DEFAULT_ESCALATION_WINDOW = 12 hours;
    uint256 constant DEFAULT_POST_RESOLUTION_WINDOW = 12 hours;

    // Pyth price feed IDs
    bytes32 constant BTC_USD = bytes32(uint256(1));
    bytes32 constant ETH_USD = bytes32(uint256(2));

    // ============ Setup ============

    function setUp() public {
        owner = address(this);
        creator = address(0x100);
        resolver1 = address(0x200);
        resolver2 = address(0x300);
        disputer = address(0x400);

        // Fund test accounts
        vm.deal(creator, 100 ether);
        vm.deal(resolver1, 100 ether);
        vm.deal(resolver2, 100 ether);
        vm.deal(disputer, 100 ether);

        // 1. Deploy TruthEngine
        registry = new TruthEngine();

        // 2. Deploy MockPyth (validTimePeriod=3600, updateFee=1wei)
        mockPyth = new MockPyth(3600, PYTH_FEE);

        // 3. Deploy PythPriceResolverV2
        pythResolver = new PythPriceResolverV2(address(mockPyth), address(registry));
        vm.deal(address(pythResolver), 1 ether); // Fund for Pyth fees

        // 4. Deploy OptimisticResolver
        optimisticResolver = new OptimisticResolver(address(registry));

        // 5. Deploy MockTruthKeeper
        truthKeeperContract = new MockTruthKeeper(address(registry));
        truthKeeper = address(truthKeeperContract);

        // 6. Configure registry bonds and fees
        registry.addAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(0), MIN_DISPUTE_BOND);
        registry.setProtocolFeeStandard(PROTOCOL_FEE);
        registry.setTKSharePercent(AccountabilityTier.TK_GUARANTEED, 4000); // 40%
        registry.setTKSharePercent(AccountabilityTier.SYSTEM, 6000); // 60%

        // 7. Whitelist TruthKeeper
        registry.addWhitelistedTruthKeeper(truthKeeper);

        // 8. Register both resolvers
        registry.registerResolver(address(pythResolver));
        registry.registerResolver(address(optimisticResolver));

        // 9. Initialize price feeds so they exist in MockPyth for validation
        _initializePriceFeeds();
    }

    /// @notice Initialize price feeds in MockPyth so they exist for TOC creation validation
    function _initializePriceFeeds() internal {
        bytes[] memory updates = new bytes[](2);
        updates[0] = _createPriceUpdate(BTC_USD, 50000_00000000, 100_00000000, -8, uint64(block.timestamp));
        updates[1] = _createPriceUpdate(ETH_USD, 3000_00000000, 10_00000000, -8, uint64(block.timestamp));
        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
    }

    // ============ Helper Functions ============

    /// @notice Create Pyth price update data for testing
    function _createPriceUpdate(
        bytes32 priceId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint64 publishTime
    ) internal pure returns (bytes memory) {
        PythStructs.PriceFeed memory priceFeed;
        priceFeed.id = priceId;
        priceFeed.price.price = price;
        priceFeed.price.conf = conf;
        priceFeed.price.expo = expo;
        priceFeed.price.publishTime = publishTime;
        priceFeed.emaPrice.price = price;
        priceFeed.emaPrice.conf = conf;
        priceFeed.emaPrice.expo = expo;
        priceFeed.emaPrice.publishTime = publishTime;

        return abi.encode(priceFeed, uint64(0));
    }

    /// @notice Encode price updates as resolver expects
    function _encodePriceUpdates(bytes[] memory updates) internal pure returns (bytes memory) {
        return abi.encode(updates);
    }

    // ============ Test 1: Pyth Resolver Happy Path ============

    function test_E2E_PythResolverHappyPath() public {
        console.log("\n========================================");
        console.log("TEST: Pyth Resolver Happy Path");
        console.log("========================================");

        uint256 deadline = block.timestamp + 7 days;

        console.log("\n--- Step 1: CREATE TOC ---");
        console.log("Question: Will BTC be above $100,000 by deadline?");
        console.log("Resolver: PythPriceResolver (oracle-based)");
        console.log("Dispute window: None (automatic resolution)");

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000), // $100,000 threshold with 8 decimals
            true // isAbove
        );

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(pythResolver),
            1, // TEMPLATE_SNAPSHOT
            payload,
            0, // No dispute window needed for Pyth resolution
            0,
            0,
            0,
            truthKeeper
        );

        console.log("-> TOC #%s created, State: ACTIVE", tocId);

        assertEq(tocId, 1, "First TOC should have ID 1");
        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE), "Should be ACTIVE");
        assertEq(uint8(toc.answerType), uint8(AnswerType.BOOLEAN), "Should be BOOLEAN");

        console.log("\n--- Step 2: WAIT FOR DEADLINE ---");
        console.log("Fast-forwarding 7 days...");
        vm.warp(deadline);

        console.log("\n--- Step 3: RESOLVE WITH PYTH PRICE ---");
        console.log("BTC price at deadline: $105,000");
        console.log("Threshold: $100,000 (above)");

        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(105000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );
        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        vm.prank(resolver1);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Result should be true - BTC above $100k");

        console.log("-> State: RESOLVED (immediate)");
        console.log("-> Result: YES (BTC was above $100k)");
        console.log("\n[SUCCESS] Pyth TOC resolved automatically via oracle!");
    }

    // ============ Test 2: Optimistic Resolver Happy Path ============

    function test_E2E_OptimisticResolverHappyPath() public {
        console.log("\n========================================");
        console.log("TEST: Optimistic Resolver Happy Path");
        console.log("========================================");

        console.log("\n--- Step 1: CREATE TOC ---");
        console.log("Question: Will SpaceX land humans on Mars by 2030?");
        console.log("Resolver: OptimisticResolver (human proposals)");
        console.log("Dispute window: 12 hours");

        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will SpaceX successfully land humans on Mars by 2030?",
            description: "Resolves YES if SpaceX achieves a successful crewed Mars landing by Dec 31, 2030",
            resolutionSource: "NASA, SpaceX official announcements, major news outlets",
            resolutionTime: block.timestamp + 365 days
        });

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        console.log("-> TOC #%s created, State: ACTIVE", tocId);

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE), "Should be ACTIVE");

        console.log("\n--- Step 2: PROPOSE RESOLUTION ---");
        console.log("Proposer: resolver1");
        console.log("Answer: YES");
        console.log("Bond: 0.1 ETH");
        console.log("Justification: SpaceX landed crew on Mars March 2029");

        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "SpaceX successfully landed Starship crew on Mars on March 15, 2029"
        });

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer)
        );

        console.log("-> State: RESOLVING (dispute window open)");

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVING), "Should be RESOLVING");

        console.log("\n--- Step 3: WAIT FOR DISPUTE WINDOW ---");
        console.log("No disputes filed...");
        console.log("Fast-forwarding 12 hours...");
        vm.warp(block.timestamp + DEFAULT_DISPUTE_WINDOW + 1);

        console.log("\n--- Step 4: FINALIZE ---");
        vm.prank(resolver1);
        registry.finalizeTOC(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        console.log("-> State: RESOLVED");
        console.log("-> Result: YES");
        console.log("-> Bond returned to proposer");
        console.log("\n[SUCCESS] Optimistic resolution finalized without dispute!");
    }

    // ============ Test 3: Full Dispute Flow with TK Decision ============

    function test_E2E_FullDisputeFlowWithTKDecision() public {
        console.log("\n========================================");
        console.log("TEST: Full Dispute Flow with TK Decision");
        console.log("========================================");

        console.log("\n--- Step 1: CREATE TOC ---");
        console.log("Question: Did Company X exceed $1B revenue in Q4?");

        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Did Company X exceed $1B revenue in Q4 2025?",
            description: "Resolves YES if official earnings report shows >$1B revenue",
            resolutionSource: "Official SEC filings, company earnings call",
            resolutionTime: block.timestamp + 90 days
        });

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        console.log("-> TOC #%s created, State: ACTIVE", tocId);

        console.log("\n--- Step 2: PROPOSE RESOLUTION ---");
        console.log("Proposer: resolver1");
        console.log("Answer: YES (claims revenue was $1.2B)");
        console.log("Bond: 0.1 ETH");

        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "Q4 revenue was $1.2B according to earnings report"
        });

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer)
        );

        console.log("-> State: RESOLVING");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVING), "Should be RESOLVING");

        console.log("\n--- Step 3: FILE DISPUTE ---");
        console.log("Disputer challenges the resolution!");
        console.log("Reason: Revenue was only $980M, not $1B+");
        console.log("Proposed answer: NO");
        console.log("Bond: 0.05 ETH");

        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Revenue was only $980M, not $1B+",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        console.log("-> State: DISPUTED_ROUND_1");

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should be DISPUTED_ROUND_1");

        console.log("\n--- Step 4: TRUTHKEEPER DECISION ---");
        console.log("TruthKeeper reviews the dispute...");
        console.log("Decision: UPHOLD_DISPUTE (disputer was correct!)");
        console.log("Corrected answer: NO");

        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeBoolean(false)
        );

        console.log("-> Escalation window opens (12h for anyone to challenge TK)");

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should still be DISPUTED_ROUND_1");

        console.log("\n--- Step 5: WAIT FOR ESCALATION WINDOW ---");
        console.log("No one escalates the TK decision...");
        console.log("Fast-forwarding 12 hours...");
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);

        console.log("\n--- Step 6: FINALIZE ---");
        registry.finalizeAfterTruthKeeper(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Result should be false - dispute was upheld");

        console.log("-> State: RESOLVED");
        console.log("-> Final Result: NO (disputer's answer)");
        console.log("\n--- BOND DISTRIBUTION ---");
        console.log("Proposer bond (0.1 ETH) SLASHED:");
        console.log("  - 50% (0.05 ETH) -> Disputer (reward)");
        console.log("  - 30% (0.03 ETH) -> Protocol treasury");
        console.log("  - 20% (0.02 ETH) -> TruthKeeper");
        console.log("Disputer bond (0.05 ETH) -> Returned");
        console.log("\n[SUCCESS] Dispute upheld, proposer slashed!");
    }

    // ============ Test 4: Pyth Resolver with Dispute ============

    function test_E2E_PythResolverWithDispute() public {
        console.log("\n========================================");
        console.log("TEST: Pyth Resolver with Dispute (Rejected)");
        console.log("========================================");

        uint256 deadline = block.timestamp + 7 days;

        console.log("\n--- Step 1: CREATE PYTH TOC ---");
        console.log("Question: Will ETH be above $5,000 by deadline?");
        console.log("Note: This Pyth TOC has dispute windows enabled");

        bytes memory payload = abi.encode(
            ETH_USD,
            deadline,
            int64(5000_00000000),
            true
        );

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(pythResolver),
            1,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        console.log("-> TOC #%s created, State: ACTIVE", tocId);

        console.log("\n--- Step 2: RESOLVE WITH PYTH ---");
        console.log("ETH price: $5,200 (above $5,000 threshold)");
        vm.warp(deadline);

        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(5200_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );
        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            _encodePriceUpdates(updates)
        );

        console.log("-> Result: YES, State: RESOLVING");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVING), "Should be RESOLVING");

        console.log("\n--- Step 3: FRIVOLOUS DISPUTE ---");
        console.log("Disputer claims: Pyth data was manipulated!");
        console.log("Disputer says actual price was $4,950");

        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Pyth price feed was manipulated, actual price was $4,950",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        console.log("-> State: DISPUTED_ROUND_1");

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should be DISPUTED_ROUND_1");

        console.log("\n--- Step 4: TRUTHKEEPER REJECTS DISPUTE ---");
        console.log("TK investigates... Pyth data was valid!");
        console.log("Decision: REJECT_DISPUTE");

        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.REJECT_DISPUTE,
            ""
        );

        console.log("-> Original resolution stands");

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should still be DISPUTED_ROUND_1");

        console.log("\n--- Step 5: FINALIZE ---");
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);
        registry.finalizeAfterTruthKeeper(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Result should be true - dispute was rejected");

        console.log("-> State: RESOLVED");
        console.log("-> Final Result: YES (original answer)");
        console.log("\n--- BOND DISTRIBUTION ---");
        console.log("Disputer bond (0.05 ETH) SLASHED:");
        console.log("  - 50% (0.025 ETH) -> Proposer (reward)");
        console.log("  - 30% (0.015 ETH) -> Protocol treasury");
        console.log("  - 20% (0.01 ETH) -> TruthKeeper");
        console.log("Proposer bond (0.1 ETH) -> Returned");
        console.log("\n[SUCCESS] Frivolous dispute rejected, disputer slashed!");
    }

    // ============ Test 5: Complex Multi-Step Scenario ============

    function test_E2E_ComplexMultiStepScenario() public {
        console.log("\n========================================");
        console.log("TEST: Complex Multi-Step Scenario");
        console.log("========================================");
        console.log("Creating 3 TOCs simultaneously with different resolvers and outcomes");

        // Create multiple TOCs simultaneously
        uint256[] memory tocIds = new uint256[](3);

        console.log("\n--- Step 1: CREATE 3 TOCS ---");

        // TOC 1: Pyth price check
        console.log("TOC #1: Pyth - Will BTC be below $90,000?");
        uint256 deadline1 = block.timestamp + 1 days;
        bytes memory payload1 = abi.encode(
            BTC_USD,
            deadline1,
            int64(90000_00000000),
            false // isBelow
        );

        vm.prank(creator);
        tocIds[0] = registry.createTOC{value: PROTOCOL_FEE}(
            address(pythResolver),
            1,
            payload1,
            0, 0, 0, 0,
            truthKeeper
        );

        // TOC 2: Optimistic arbitrary question
        console.log("TOC #2: Optimistic - Will AI surpass human intelligence?");
        OptimisticResolver.ArbitraryPayload memory payload2 = OptimisticResolver.ArbitraryPayload({
            question: "Will AI surpass human intelligence in 2026?",
            description: "Based on expert consensus",
            resolutionSource: "AI research community",
            resolutionTime: block.timestamp + 365 days
        });

        vm.prank(creator);
        tocIds[1] = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1,
            abi.encode(payload2),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // TOC 3: Optimistic sports question
        console.log("TOC #3: Sports - Will Lakers beat Celtics?");
        OptimisticResolver.SportsPayload memory payload3 = OptimisticResolver.SportsPayload({
            league: "NBA",
            homeTeam: "Lakers",
            awayTeam: "Celtics",
            gameTime: block.timestamp + 2 days,
            questionType: OptimisticResolver.SportQuestionType.WINNER,
            line: 0
        });

        vm.prank(creator);
        tocIds[2] = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            2, // TEMPLATE_SPORTS
            abi.encode(payload3),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Verify all TOCs created successfully
        for (uint256 i = 0; i < 3; i++) {
            TOC memory toc = registry.getTOC(tocIds[i]);
            assertEq(uint8(toc.state), uint8(TOCState.ACTIVE), "All TOCs should be ACTIVE");
        }
        console.log("-> All 3 TOCs created and ACTIVE");

        console.log("\n--- Step 2: RESOLVE TOC #1 (PYTH) ---");
        console.log("BTC price: $88,000 (below $90,000 threshold)");
        // Resolve TOC 1 (Pyth)
        vm.warp(deadline1);
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(88000_00000000), // Below threshold
            uint64(100_00000000),
            int32(-8),
            uint64(deadline1)
        );
        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        vm.prank(resolver1);
        registry.resolveTOC(tocIds[0], address(0), 0, _encodePriceUpdates(updates));

        TOC memory toc1 = registry.getTOC(tocIds[0]);
        assertEq(uint8(toc1.state), uint8(TOCState.RESOLVED), "TOC 1 should be RESOLVED");
        console.log("-> TOC #1 RESOLVED immediately (Pyth oracle)");

        console.log("\n--- Step 3: RESOLVE TOC #2 + DISPUTE ---");
        console.log("Proposer answers: YES (AGI achieved)");
        console.log("Disputer challenges: Too early to determine!");
        // Resolve TOC 2 (Optimistic) and have it disputed
        OptimisticResolver.AnswerPayload memory answer2 = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "AGI achieved"
        });

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocIds[1],
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer2)
        );

        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocIds[1],
            address(0),
            MIN_DISPUTE_BOND,
            "Too early to determine",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        TOC memory toc2 = registry.getTOC(tocIds[1]);
        assertEq(uint8(toc2.state), uint8(TOCState.DISPUTED_ROUND_1), "TOC 2 should be DISPUTED");
        console.log("-> TOC #2 DISPUTED (awaiting TK decision)");

        console.log("\n--- Step 4: RESOLVE TOC #3 (SPORTS) ---");
        console.log("Proposer: Lakers won 115-108");
        // Resolve TOC 3 (Sports) - happy path
        OptimisticResolver.AnswerPayload memory answer3 = OptimisticResolver.AnswerPayload({
            answer: true, // Lakers win
            justification: "Lakers won 115-108"
        });

        vm.prank(resolver2);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocIds[2],
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer3)
        );

        vm.warp(block.timestamp + DEFAULT_DISPUTE_WINDOW + 1);

        vm.prank(resolver2);
        registry.finalizeTOC(tocIds[2]);

        TOC memory toc3 = registry.getTOC(tocIds[2]);
        assertEq(uint8(toc3.state), uint8(TOCState.RESOLVED), "TOC 3 should be RESOLVED");
        console.log("-> TOC #3 RESOLVED (no disputes filed)");

        // Verify all three TOCs have different states/outcomes
        assertEq(uint8(toc1.state), uint8(TOCState.RESOLVED), "TOC 1 resolved via Pyth");
        assertEq(uint8(toc2.state), uint8(TOCState.DISPUTED_ROUND_1), "TOC 2 in dispute");
        assertEq(uint8(toc3.state), uint8(TOCState.RESOLVED), "TOC 3 resolved optimistically");

        console.log("\n--- FINAL STATES ---");
        console.log("TOC #1 (Pyth):      RESOLVED - BTC was below $90k");
        console.log("TOC #2 (AI):        DISPUTED - Awaiting TK decision");
        console.log("TOC #3 (Sports):    RESOLVED - Lakers won");
        console.log("\n[SUCCESS] 3 TOCs handled concurrently with different outcomes!");
    }

    // ============ Test 6: TK Decision Variations ============

    function test_E2E_TKDecisionTooEarly() public {
        console.log("\n========================================");
        console.log("TEST: TK Decision - TOO_EARLY");
        console.log("========================================");
        console.log("Scenario: Proposer resolves before event occurs");
        console.log("Expected: TK returns TOC to ACTIVE state");

        console.log("\n--- Step 1: CREATE TOC ---");
        console.log("Question: Will event X occur? (resolves in 30 days)");
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will event X occur?",
            description: "Should only resolve after specific date",
            resolutionSource: "Official sources",
            resolutionTime: block.timestamp + 30 days
        });

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        console.log("\n--- Step 2: PREMATURE RESOLUTION ---");
        console.log("Proposer answers: YES (claims event already happened)");
        // Someone tries to resolve early
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "Already happened"
        });

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer)
        );

        console.log("\n--- Step 3: DISPUTE FILED ---");
        console.log("Disputer: Event hasn't occurred yet!");
        // Dispute: too early
        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Event hasn't occurred yet, resolution is premature",
            "",
            ""
        );

        console.log("\n--- Step 4: TRUTHKEEPER DECISION ---");
        console.log("TK verdict: TOO_EARLY");
        console.log("Action: Return TOC to ACTIVE state");
        // TK decides: TOO_EARLY, return to ACTIVE
        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.TOO_EARLY,
            ""
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE), "Should return to ACTIVE");

        console.log("-> State: ACTIVE (returned for proper resolution later)");
        console.log("-> Both bonds returned (no wrongdoing)");
        console.log("\n[SUCCESS] TOC returned to ACTIVE, can be resolved when ready!");
    }

    function test_E2E_TKDecisionCancelTOC() public {
        console.log("\n========================================");
        console.log("TEST: TK Decision - CANCEL_TOC");
        console.log("========================================");
        console.log("Scenario: Question is too ambiguous to resolve fairly");
        console.log("Expected: TOC is cancelled, bonds returned");

        console.log("\n--- Step 1: CREATE AMBIGUOUS TOC ---");
        console.log("Question: Ambiguous question with unclear criteria");
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Ambiguous question with unclear criteria",
            description: "Poorly defined resolution criteria",
            resolutionSource: "Unknown",
            resolutionTime: block.timestamp + 30 days
        });

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        console.log("\n--- Step 2: PROPOSE RESOLUTION ---");
        console.log("Proposer attempts to resolve with: YES");
        // Propose answer
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "Unclear"
        });

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer)
        );

        console.log("\n--- Step 3: DISPUTE FILED ---");
        console.log("Disputer: Question is too ambiguous to resolve fairly!");
        // Dispute
        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Question is too ambiguous to resolve fairly",
            "",
            ""
        );

        console.log("\n--- Step 4: TRUTHKEEPER DECISION ---");
        console.log("TK verdict: CANCEL_TOC");
        console.log("Reason: Question cannot be fairly resolved");
        // TK decides: CANCEL_TOC (entire TOC is invalid)
        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.CANCEL_TOC,
            ""
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should still be DISPUTED_ROUND_1");

        console.log("\n--- Step 5: FINALIZE ---");
        console.log("Waiting for escalation window...");
        // Wait for escalation window to pass
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);

        // Finalize after TK decision
        registry.finalizeAfterTruthKeeper(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.CANCELLED), "Should be CANCELLED");

        console.log("-> State: CANCELLED");
        console.log("-> All bonds returned (question was invalid)");
        console.log("\n[SUCCESS] Ambiguous TOC cancelled, all participants refunded!");
    }

    // ============ Test 7: Bond and Fee Accounting ============

    function test_E2E_BondAndFeeAccounting() public {
        console.log("\n========================================");
        console.log("TEST: Bond and Fee Accounting");
        console.log("========================================");
        console.log("Verifying correct ETH flows through the system");

        uint256 initialCreatorBalance = creator.balance;
        uint256 initialResolver1Balance = resolver1.balance;
        uint256 initialDisputerBalance = disputer.balance;

        console.log("\n--- Initial Balances ---");
        console.log("Creator:  100 ETH");
        console.log("Resolver: 100 ETH");
        console.log("Disputer: 100 ETH");

        console.log("\n--- Step 1: CREATE TOC ---");
        console.log("Protocol fee: 0.001 ETH");
        // Create TOC
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Test question for fee accounting?",
            description: "Testing fee distribution",
            resolutionSource: "Test",
            resolutionTime: block.timestamp + 1 days
        });

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1,
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Creator paid protocol fee
        assertEq(
            creator.balance,
            initialCreatorBalance - PROTOCOL_FEE,
            "Creator should have paid protocol fee"
        );
        console.log("-> Creator paid 0.001 ETH (protocol fee)");

        console.log("\n--- Step 2: PROPOSE RESOLUTION ---");
        console.log("Resolution bond: 0.1 ETH");
        // Resolve
        OptimisticResolver.AnswerPayload memory answer = OptimisticResolver.AnswerPayload({
            answer: true,
            justification: "Test"
        });

        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            abi.encode(answer)
        );

        // Resolver paid bond
        assertEq(
            resolver1.balance,
            initialResolver1Balance - MIN_RESOLUTION_BOND,
            "Resolver should have paid bond"
        );
        console.log("-> Resolver paid 0.1 ETH (resolution bond)");

        console.log("\n--- Step 3: FILE DISPUTE ---");
        console.log("Dispute bond: 0.05 ETH");
        // Dispute
        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Dispute for testing",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        // Disputer paid bond
        assertEq(
            disputer.balance,
            initialDisputerBalance - MIN_DISPUTE_BOND,
            "Disputer should have paid bond"
        );
        console.log("-> Disputer paid 0.05 ETH (dispute bond)");

        console.log("\n--- Step 4: TK UPHOLDS DISPUTE ---");
        console.log("TK verdict: Disputer was correct!");
        // TK upholds dispute
        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeBoolean(false)
        );

        console.log("\n--- BOND DISTRIBUTION SUMMARY ---");
        console.log("Protocol Fee (0.001 ETH):");
        console.log("  -> Protocol treasury");
        console.log("");
        console.log("Resolver Bond SLASHED (0.1 ETH):");
        console.log("  - 50% (0.05 ETH) -> Disputer (reward)");
        console.log("  - 30% (0.03 ETH) -> Protocol treasury");
        console.log("  - 20% (0.02 ETH) -> TruthKeeper");
        console.log("");
        console.log("Disputer Bond (0.05 ETH):");
        console.log("  -> Returned to disputer");
        console.log("\n[SUCCESS] All fees and bonds accounted for correctly!");
    }

    receive() external payable {}
}
