// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "contracts/TOCRegistry/TOCRegistry.sol";
import "contracts/TOCRegistry/TOCTypes.sol";
import "contracts/TOCRegistry/ITOCRegistry.sol";
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
    TOCRegistry public registry;
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

        // 1. Deploy TOCRegistry
        registry = new TOCRegistry();

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
        uint256 deadline = block.timestamp + 7 days;

        // Create a Snapshot TOC: Will BTC be above $100k by deadline?
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

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE), "Should be ACTIVE");
        assertEq(uint8(toc.answerType), uint8(AnswerType.BOOLEAN), "Should be BOOLEAN");

        // Wait for deadline
        vm.warp(deadline);

        // Create price update: BTC is at $105,000 (above threshold)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(105000_00000000),
            uint64(100_00000000), // conf: $100
            int32(-8),
            uint64(deadline)
        );

        // Update mock Pyth
        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Resolve with valid Pyth proof
        vm.prank(resolver1);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Verify state is RESOLVED (no dispute window for Pyth)
        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        // Verify result is correct (true = above threshold)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Result should be true - BTC above $100k");
    }

    // ============ Test 2: Optimistic Resolver Happy Path ============

    function test_E2E_OptimisticResolverHappyPath() public {
        // Create an Arbitrary question TOC
        OptimisticResolver.ArbitraryPayload memory payload = OptimisticResolver.ArbitraryPayload({
            question: "Will SpaceX successfully land humans on Mars by 2030?",
            description: "Resolves YES if SpaceX achieves a successful crewed Mars landing by Dec 31, 2030",
            resolutionSource: "NASA, SpaceX official announcements, major news outlets",
            resolutionTime: block.timestamp + 365 days
        });

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(optimisticResolver),
            1, // TEMPLATE_ARBITRARY
            abi.encode(payload),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE), "Should be ACTIVE");

        // Propose answer with bond
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

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVING), "Should be RESOLVING");

        // Wait for dispute window to pass
        vm.warp(block.timestamp + DEFAULT_DISPUTE_WINDOW + 1);

        // Finalize
        vm.prank(resolver1);
        registry.finalizeTOC(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        // Bond is automatically returned during finalization
        // (no explicit withdrawal needed in this happy path)
    }

    // ============ Test 3: Full Dispute Flow with TK Decision ============

    function test_E2E_FullDisputeFlowWithTKDecision() public {
        // Create TOC with dispute window
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

        // Propose answer: YES
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

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVING), "Should be RESOLVING");

        // File dispute (claiming answer should be NO)
        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Revenue was only $980M, not $1B+",
            "",
            TOCResultCodec.encodeBoolean(false) // Propose NO
        );

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should be DISPUTED_ROUND_1");

        // TruthKeeper decides: Accept dispute (disputer was correct)
        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeBoolean(false)
        );

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should still be DISPUTED_ROUND_1");

        // Wait for escalation window to pass (no one challenges TK decision)
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);

        // Finalize after TK decision
        registry.finalizeAfterTruthKeeper(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        // Verify result is NO (disputer's proposed result)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Result should be false - dispute was upheld");

        // Bonds are automatically transferred:
        // - Disputer gets their bond back + 50% of resolver's bond
        // - Resolver's bond is slashed (50% to disputer, 50% to protocol/TK)
    }

    // ============ Test 4: Pyth Resolver with Dispute ============

    function test_E2E_PythResolverWithDispute() public {
        uint256 deadline = block.timestamp + 7 days;

        // Create Pyth TOC with dispute windows enabled
        bytes memory payload = abi.encode(
            ETH_USD,
            deadline,
            int64(5000_00000000), // $5,000 threshold
            true // isAbove
        );

        vm.prank(creator);
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(pythResolver),
            1, // TEMPLATE_SNAPSHOT
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create price update: ETH at $5,200 (above threshold)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(5200_00000000),
            uint64(10_00000000), // conf: $10
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Resolve with proof
        vm.prank(resolver1);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            _encodePriceUpdates(updates)
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVING), "Should be RESOLVING");

        // Someone disputes claiming the Pyth data was manipulated
        vm.prank(disputer);
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Pyth price feed was manipulated, actual price was $4,950",
            "",
            TOCResultCodec.encodeBoolean(false) // Claim it should be false
        );

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should be DISPUTED_ROUND_1");

        // TK investigates and rejects the dispute (original resolution was correct)
        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.REJECT_DISPUTE,
            "" // No corrected result needed, original stands
        );

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.DISPUTED_ROUND_1), "Should still be DISPUTED_ROUND_1");

        // Wait for escalation window to pass
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);

        // Finalize after TK decision
        registry.finalizeAfterTruthKeeper(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Should be RESOLVED");

        // Verify result is still true (original resolution upheld)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Result should be true - dispute was rejected");

        // Bonds are automatically transferred:
        // - Resolver gets their bond back + 50% of disputer's bond
        // - Disputer's bond is slashed (50% to resolver, 50% to protocol/TK)
    }

    // ============ Test 5: Complex Multi-Step Scenario ============

    function test_E2E_ComplexMultiStepScenario() public {
        // Create multiple TOCs simultaneously
        uint256[] memory tocIds = new uint256[](3);

        // TOC 1: Pyth price check
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

        // Verify all three TOCs have different states/outcomes
        assertEq(uint8(toc1.state), uint8(TOCState.RESOLVED), "TOC 1 resolved via Pyth");
        assertEq(uint8(toc2.state), uint8(TOCState.DISPUTED_ROUND_1), "TOC 2 in dispute");
        assertEq(uint8(toc3.state), uint8(TOCState.RESOLVED), "TOC 3 resolved optimistically");
    }

    // ============ Test 6: TK Decision Variations ============

    function test_E2E_TKDecisionTooEarly() public {
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
    }

    function test_E2E_TKDecisionCancelTOC() public {
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

        // Wait for escalation window to pass
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);

        // Finalize after TK decision
        registry.finalizeAfterTruthKeeper(tocId);

        toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.CANCELLED), "Should be CANCELLED");
    }

    // ============ Test 7: Bond and Fee Accounting ============

    function test_E2E_BondAndFeeAccounting() public {
        uint256 initialCreatorBalance = creator.balance;
        uint256 initialResolver1Balance = resolver1.balance;
        uint256 initialDisputerBalance = disputer.balance;

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

        // TK upholds dispute
        vm.prank(truthKeeper);
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeBoolean(false)
        );

        // Bonds are automatically transferred when TK resolves:
        // - Disputer gets bond back + 50% of resolver's slashed bond
        // - Resolver's bond is slashed (50% to disputer, 50% to fees)
    }

    receive() external payable {}
}
