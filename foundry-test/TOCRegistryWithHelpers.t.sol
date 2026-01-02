// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "./TestHelpers.sol";
import "contracts/TOCRegistry/TOCRegistry.sol";
import "contracts/TOCRegistry/TOCTypes.sol";
import "./MockResolver.sol";
import "./MockERC20.sol";
import "./MockTruthKeeper.sol";
import "contracts/libraries/TOCResultCodec.sol";

/// @title TOCRegistryWithHelpersTest
/// @notice Demonstrates usage of TestHelpers for comprehensive test verification
/// @dev Each test uses helpers that verify all effects: state changes, events, and internal calls
contract TOCRegistryWithHelpersTest is TestHelpers {
    TOCRegistry registry;
    MockResolver resolver;
    MockERC20 bondToken;
    MockTruthKeeper truthKeeperContract;

    address owner;
    address user1;
    address user2;
    address disputer;

    uint256 constant MIN_RESOLUTION_BOND = 0.1 ether;
    uint256 constant MIN_DISPUTE_BOND = 0.05 ether;
    uint256 constant MIN_ESCALATION_BOND = 0.15 ether;
    uint256 constant DEFAULT_DISPUTE_WINDOW = 24 hours;
    uint256 constant DEFAULT_TK_WINDOW = 24 hours;
    uint256 constant DEFAULT_ESCALATION_WINDOW = 24 hours; // Max for RESOLVER trust level is 1 day
    uint256 constant DEFAULT_POST_RESOLUTION_WINDOW = 24 hours;
    uint256 constant PROTOCOL_FEE = 0.001 ether;

    address truthKeeper;

    // ============ Setup ============

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        disputer = address(0x3);

        // Deploy registry
        registry = new TOCRegistry();

        // Deploy mock resolver with registry address
        resolver = new MockResolver(address(registry));

        // Deploy mock TruthKeeper contract
        truthKeeperContract = new MockTruthKeeper(address(registry));
        truthKeeper = address(truthKeeperContract);

        // Deploy mock ERC20 for bond testing
        bondToken = new MockERC20("Test Token", "TEST", 18);

        // Configure acceptable bonds
        registry.addAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(0), MIN_DISPUTE_BOND);
        registry.addAcceptableEscalationBond(address(0), MIN_ESCALATION_BOND);
        registry.addAcceptableResolutionBond(address(bondToken), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(bondToken), MIN_DISPUTE_BOND);

        // Whitelist TruthKeeper
        registry.addWhitelistedTruthKeeper(truthKeeper);

        // Configure fees
        registry.setProtocolFeeStandard(PROTOCOL_FEE);
        registry.setTKSharePercent(AccountabilityTier.TK_GUARANTEED, 4000); // 40%
        registry.setTKSharePercent(AccountabilityTier.SYSTEM, 6000); // 60%

        // Register resolver
        registry.registerResolver(address(resolver));
    }

    // ============ TOC Creation Tests Using Helpers ============

    function test_CreateTOC_WithHelpers() public {
        CreateTOCParams memory params = CreateTOCParams({
            resolver: address(resolver),
            templateId: 0,
            payload: abi.encode("test payload"),
            disputeWindow: uint32(DEFAULT_DISPUTE_WINDOW),
            tkWindow: uint32(DEFAULT_TK_WINDOW),
            escalationWindow: uint32(DEFAULT_ESCALATION_WINDOW),
            postResolutionWindow: uint32(DEFAULT_POST_RESOLUTION_WINDOW),
            truthKeeper: truthKeeper,
            fee: PROTOCOL_FEE
        });

        CreateTOCExpected memory expected = CreateTOCExpected({
            expectedState: TOCState.ACTIVE,
            expectedAnswerType: AnswerType.BOOLEAN,
            expectedTier: AccountabilityTier.TK_GUARANTEED,
            expectedCreator: address(this)
        });

        // This single call verifies:
        // - TOC ID increment
        // - State set to ACTIVE
        // - Answer type is BOOLEAN
        // - Tier assigned correctly
        // - Fee distribution (protocol + TK)
        // - All expected events emitted
        uint256 tocId = _createTocAndVerify(registry, params, expected);

        assertEq(tocId, 1, "First TOC should have ID 1");
    }

    function test_CreateTOCWithSystemResolver_WithHelpers() public {
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);

        CreateTOCParams memory params = CreateTOCParams({
            resolver: address(resolver),
            templateId: 0,
            payload: abi.encode("test payload"),
            disputeWindow: uint32(DEFAULT_DISPUTE_WINDOW),
            tkWindow: uint32(DEFAULT_TK_WINDOW),
            escalationWindow: uint32(DEFAULT_ESCALATION_WINDOW),
            postResolutionWindow: uint32(DEFAULT_POST_RESOLUTION_WINDOW),
            truthKeeper: truthKeeper,
            fee: PROTOCOL_FEE
        });

        CreateTOCExpected memory expected = CreateTOCExpected({
            expectedState: TOCState.ACTIVE,
            expectedAnswerType: AnswerType.BOOLEAN,
            expectedTier: AccountabilityTier.SYSTEM, // SYSTEM tier for SYSTEM resolver
            expectedCreator: address(this)
        });

        _createTocAndVerify(registry, params, expected);
    }

    function test_CreateUndisputableTOC_WithHelpers() public {
        CreateTOCParams memory params = CreateTOCParams({
            resolver: address(resolver),
            templateId: 0,
            payload: abi.encode("test payload"),
            disputeWindow: 0,
            tkWindow: 0,
            escalationWindow: 0,
            postResolutionWindow: 0, // All windows = 0 means undisputable
            truthKeeper: truthKeeper,
            fee: PROTOCOL_FEE
        });

        CreateTOCExpected memory expected = CreateTOCExpected({
            expectedState: TOCState.ACTIVE,
            expectedAnswerType: AnswerType.BOOLEAN,
            expectedTier: AccountabilityTier.TK_GUARANTEED,
            expectedCreator: address(this)
        });

        uint256 tocId = _createTocAndVerify(registry, params, expected);

        // Verify the TOC's windows are all 0
        TOC memory toc = registry.getTOC(tocId);
        assertEq(toc.disputeWindow, 0, "Dispute window should be 0");
        assertEq(toc.postResolutionWindow, 0, "Post resolution window should be 0");
    }

    // ============ Resolution Tests Using Helpers ============

    function test_ResolveTOCWithBond_WithHelpers() public {
        // First create a TOC
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(resolver),
            0,
            abi.encode("test"),
            uint32(DEFAULT_DISPUTE_WINDOW),
            uint32(DEFAULT_TK_WINDOW),
            uint32(DEFAULT_ESCALATION_WINDOW),
            uint32(DEFAULT_POST_RESOLUTION_WINDOW),
            truthKeeper
        );

        bytes memory expectedResult = TOCResultCodec.encodeBoolean(true);

        ResolveTOCParams memory params = ResolveTOCParams({
            tocId: tocId,
            bondToken: address(0),
            bondAmount: MIN_RESOLUTION_BOND,
            resolverPayload: ""
        });

        ResolveTOCExpected memory expected = ResolveTOCExpected({
            expectedState: TOCState.RESOLVING,
            expectBondEvent: true,
            expectedResult: expectedResult
        });

        // This single call verifies:
        // - State changed to RESOLVING
        // - Dispute deadline set in future
        // - Bond stored correctly
        // - Result stored correctly
        // - ResolutionProposed event emitted
        // - BondPosted event emitted
        // - TOCStateChanged event emitted
        _resolveTocAndVerify(registry, params, expected);
    }

    function test_ResolveUndisputableTOC_WithHelpers() public {
        // Create undisputable TOC
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(resolver),
            0,
            abi.encode("test"),
            0, 0, 0, 0, // All windows = 0
            truthKeeper
        );

        bytes memory expectedResult = TOCResultCodec.encodeBoolean(true);

        ResolveTOCParams memory params = ResolveTOCParams({
            tocId: tocId,
            bondToken: address(0),
            bondAmount: 0, // No bond needed for undisputable
            resolverPayload: ""
        });

        ResolveTOCExpected memory expected = ResolveTOCExpected({
            expectedState: TOCState.RESOLVED, // Goes directly to RESOLVED
            expectBondEvent: false,
            expectedResult: expectedResult
        });

        _resolveTocAndVerify(registry, params, expected);

        // Verify fully finalized
        assertTrue(registry.isFullyFinalized(tocId), "Should be fully finalized");
    }

    // ============ Dispute Tests Using Helpers ============

    function test_DisputeTOC_WithHelpers() public {
        // Create and resolve TOC
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(resolver),
            0,
            abi.encode("test"),
            uint32(DEFAULT_DISPUTE_WINDOW),
            uint32(DEFAULT_TK_WINDOW),
            uint32(DEFAULT_ESCALATION_WINDOW),
            uint32(DEFAULT_POST_RESOLUTION_WINDOW),
            truthKeeper
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            ""
        );

        DisputeParams memory params = DisputeParams({
            tocId: tocId,
            bondToken: address(0),
            bondAmount: MIN_DISPUTE_BOND,
            reason: "Incorrect outcome",
            evidenceURI: "ipfs://evidence",
            proposedResult: TOCResultCodec.encodeBoolean(false)
        });

        DisputeExpected memory expected = DisputeExpected({
            expectedState: TOCState.DISPUTED_ROUND_1,
            expectedPhase: DisputePhase.PRE_RESOLUTION,
            expectedDisputer: address(this)
        });

        // This single call verifies:
        // - State changed to DISPUTED_ROUND_1
        // - Dispute info stored correctly (disputer, reason, phase, bond)
        // - Bond received
        // - TOCDisputed event emitted
        // - BondPosted event emitted
        // - TOCStateChanged event emitted
        _disputeAndVerify(registry, params, expected);
    }

    // ============ Full Flow Test Using Helpers ============

    function test_FullLifecycle_WithHelpers() public {
        // 1. Create TOC with full verification
        CreateTOCParams memory createParams = CreateTOCParams({
            resolver: address(resolver),
            templateId: 0,
            payload: abi.encode("Will BTC hit $100k?"),
            disputeWindow: uint32(DEFAULT_DISPUTE_WINDOW),
            tkWindow: uint32(DEFAULT_TK_WINDOW),
            escalationWindow: uint32(DEFAULT_ESCALATION_WINDOW),
            postResolutionWindow: uint32(DEFAULT_POST_RESOLUTION_WINDOW),
            truthKeeper: truthKeeper,
            fee: PROTOCOL_FEE
        });

        CreateTOCExpected memory createExpected = CreateTOCExpected({
            expectedState: TOCState.ACTIVE,
            expectedAnswerType: AnswerType.BOOLEAN,
            expectedTier: AccountabilityTier.TK_GUARANTEED,
            expectedCreator: address(this)
        });

        uint256 tocId = _createTocAndVerify(registry, createParams, createExpected);

        // 2. Resolve TOC with full verification
        bytes memory expectedResult = TOCResultCodec.encodeBoolean(true);

        ResolveTOCParams memory resolveParams = ResolveTOCParams({
            tocId: tocId,
            bondToken: address(0),
            bondAmount: MIN_RESOLUTION_BOND,
            resolverPayload: ""
        });

        ResolveTOCExpected memory resolveExpected = ResolveTOCExpected({
            expectedState: TOCState.RESOLVING,
            expectBondEvent: true,
            expectedResult: expectedResult
        });

        _resolveTocAndVerify(registry, resolveParams, resolveExpected);

        // 3. Warp past dispute window
        _warpForward(DEFAULT_DISPUTE_WINDOW + 1);

        // 4. Finalize with full verification
        _finalizeAndVerify(registry, tocId, expectedResult);

        // 5. Verify final state
        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.RESOLVED), "Final state should be RESOLVED");

        // 6. Verify post-resolution window still open
        assertFalse(registry.isFullyFinalized(tocId), "Should not be fully finalized yet");

        // 7. Warp past post-resolution window
        _warpForward(DEFAULT_POST_RESOLUTION_WINDOW + 1);

        // 8. Now should be fully finalized
        assertTrue(registry.isFullyFinalized(tocId), "Should be fully finalized");
    }

    // ============ Dispute Resolution Test Using Helpers ============

    function test_DisputeAndResolve_WithHelpers() public {
        // Create TOC with no pre-resolution dispute window, only post-resolution
        uint256 tocId = registry.createTOC{value: PROTOCOL_FEE}(
            address(resolver),
            0,
            abi.encode("test"),
            0, // no pre-resolution dispute
            uint32(DEFAULT_TK_WINDOW),
            uint32(DEFAULT_ESCALATION_WINDOW),
            uint32(DEFAULT_POST_RESOLUTION_WINDOW),
            truthKeeper
        );

        // Resolve immediately (goes directly to RESOLVED)
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            ""
        );

        // File post-resolution dispute
        DisputeParams memory disputeParams = DisputeParams({
            tocId: tocId,
            bondToken: address(0),
            bondAmount: MIN_DISPUTE_BOND,
            reason: "Wrong outcome",
            evidenceURI: "",
            proposedResult: TOCResultCodec.encodeBoolean(false)
        });

        DisputeExpected memory disputeExpected = DisputeExpected({
            expectedState: TOCState.RESOLVED, // Post-resolution disputes stay in RESOLVED state
            expectedPhase: DisputePhase.POST_RESOLUTION,
            expectedDisputer: address(this)
        });

        _disputeAndVerify(registry, disputeParams, disputeExpected);

        // Resolve dispute with uphold
        bytes memory correctedResult = TOCResultCodec.encodeBoolean(false);
        _resolveDisputeAndVerify(
            registry,
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            correctedResult,
            TOCState.RESOLVED
        );

        // Verify result was corrected
        bytes memory storedResult = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(storedResult);
        assertEq(result, false, "Result should be corrected to false");
    }

    // ============ Helper Method Tests ============

    function test_DefaultParams_Helper() public {
        // Test the convenience helper for default params
        bytes memory payload = abi.encode("test");

        CreateTOCParams memory params = _defaultCreateParams(
            address(resolver),
            payload,
            truthKeeper,
            PROTOCOL_FEE
        );

        assertEq(params.resolver, address(resolver), "Resolver should match");
        assertEq(params.templateId, 0, "Template should be 0");
        assertEq(params.disputeWindow, 24 hours, "Dispute window should be 24h");
        assertEq(params.postResolutionWindow, 24 hours, "Post resolution window should be 24h");
    }

    function test_DefaultExpected_Helper() public {
        CreateTOCExpected memory expected = _defaultActiveExpected(address(this));

        assertEq(uint8(expected.expectedState), uint8(TOCState.ACTIVE), "State should be ACTIVE");
        assertEq(uint8(expected.expectedAnswerType), uint8(AnswerType.BOOLEAN), "Answer type should be BOOLEAN");
        assertEq(expected.expectedCreator, address(this), "Creator should match");
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
