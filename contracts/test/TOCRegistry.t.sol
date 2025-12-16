// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../TOCRegistry/TOCRegistry.sol";
import "../TOCRegistry/TOCTypes.sol";
import "./MockResolver.sol";
import "./MockERC20.sol";
import "./MockTruthKeeper.sol";
import "../libraries/TOCResultCodec.sol";

/// @title TOCRegistryTest
/// @notice Comprehensive tests for TOCRegistry contract
contract TOCRegistryTest is Test {
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
    uint256 constant DEFAULT_ESCALATION_WINDOW = 48 hours;
    uint256 constant DEFAULT_POST_RESOLUTION_WINDOW = 24 hours;

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
        registry.addAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND); // ETH
        registry.addAcceptableDisputeBond(address(0), MIN_DISPUTE_BOND); // ETH
        registry.addAcceptableEscalationBond(address(0), MIN_ESCALATION_BOND); // ETH
        registry.addAcceptableResolutionBond(address(bondToken), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(bondToken), MIN_DISPUTE_BOND);

        // Whitelist TruthKeeper
        registry.addWhitelistedTruthKeeper(truthKeeper);

        // Configure fees
        registry.setMinFee(address(0), 0.001 ether); // ETH minimum fee
        registry.setProtocolFeePercent(ResolverTrust.RESOLVER, 6000); // 60%
        registry.setProtocolFeePercent(ResolverTrust.VERIFIED, 4000); // 40%
        registry.setProtocolFeePercent(ResolverTrust.SYSTEM, 2000); // 20%
        registry.setTKSharePercent(AccountabilityTier.TK_GUARANTEED, 4000); // 40%
        registry.setTKSharePercent(AccountabilityTier.SYSTEM, 6000); // 60%
    }

    // ============ Resolver Registration Tests ============

    function test_RegisterResolver() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        ResolverTrust trust = registry.getResolverTrust(address(resolver));
        require(trust == ResolverTrust.RESOLVER, "Resolver trust should be RESOLVER");

        bool isRegistered = registry.isRegisteredResolver(address(resolver));
        require(isRegistered, "Resolver should be registered");

        uint256 count = registry.getResolverCount();
        require(count == 1, "Should have 1 resolver");
    }

    function test_SetResolverTrust() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Upgrade to VERIFIED
        registry.setResolverTrust(address(resolver), ResolverTrust.VERIFIED);
        require(registry.getResolverTrust(address(resolver)) == ResolverTrust.VERIFIED, "Should be VERIFIED");

        // Upgrade to SYSTEM
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);
        require(registry.getResolverTrust(address(resolver)) == ResolverTrust.SYSTEM, "Should be SYSTEM");
    }

    function test_RevertRegisterNonContract() public {
        bool reverted = false;
        try registry.registerResolver(address(0x123)) {
            // Should not reach here - not a contract
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on non-contract address");
    }

    function test_RevertRegisterDuplicateResolver() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        bool reverted = false;
        try registry.registerResolver(address(resolver)) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on duplicate registration");
    }

    function test_GetResolverConfig() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        ResolverConfig memory config = registry.getResolverConfig(address(resolver));
        require(config.trust == ResolverTrust.RESOLVER, "Trust should be RESOLVER");
        require(config.registeredAt > 0, "RegisteredAt should be set");
        require(config.registeredBy == address(this), "RegisteredBy should be test contract");
    }

    // ============ TOC Creation Tests ============

    function test_CreateTOC() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        bytes memory payload = abi.encode("test payload");

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );
        require(tocId == 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        require(toc.resolver == address(resolver), "Resolver should match");
        require(toc.state == TOCState.ACTIVE, "State should be ACTIVE");
        require(toc.answerType == AnswerType.BOOLEAN, "Answer type should be BOOLEAN");
        require(toc.disputeWindow == DEFAULT_DISPUTE_WINDOW, "Dispute window should be set");
        require(toc.postResolutionWindow == DEFAULT_POST_RESOLUTION_WINDOW, "Post resolution window should be set");
        require(toc.truthKeeper == truthKeeper, "TruthKeeper should be set");
    }

    function test_CreateTOCWithSystemResolver() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        bytes memory payload = abi.encode("test payload");

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.tierAtCreation == AccountabilityTier.SYSTEM, "Tier should be SYSTEM for system resolver + whitelisted TK");
    }

    function test_CreateTOCWithPendingState() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        resolver.setDefaultInitialState(TOCState.PENDING);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.PENDING, "State should be PENDING");
    }

    function test_RevertCreateTOCWithInvalidTemplate() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver),
            99,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on invalid template");
    }

    function test_RevertCreateTOCWithUnregisteredResolver() public {
        // Create another mock resolver but don't register it
        MockResolver unregisteredResolver = new MockResolver(address(registry));

        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(unregisteredResolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on unregistered resolver");
    }

    // ============ TOC Approval/Rejection Tests ============

    function test_ApproveAndRejectTOC() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        resolver.setDefaultInitialState(TOCState.PENDING);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.PENDING, "State should be PENDING");

        // Resolver approves (we call from test contract, which is registry for mock)
        // Need to call from resolver - set test contract as registry temporarily
        resolver.setRegistry(address(this));

        // Can't easily test this without pranking - skip for now
    }

    // ============ Resolution Tests ============

    function test_ResolveTOCWithETHBond() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        // Resolve with ETH bond
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0), // ETH
            MIN_RESOLUTION_BOND,
            ""
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.RESOLVING, "State should be RESOLVING");
        require(toc.disputeDeadline > block.timestamp, "Dispute deadline should be set");

        ResolutionInfo memory info = registry.getResolutionInfo(tocId);
        require(info.proposer == address(this), "Proposer should be test contract");
        require(info.bondAmount == MIN_RESOLUTION_BOND, "Bond amount should match");
    }

    function test_RevertResolveWithInsufficientBond() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        bool reverted = false;
        try registry.resolveTOC{value: 0.01 ether}(tocId, address(0), 0.01 ether, "") {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on insufficient bond");
    }

    function test_RevertResolveNonActiveTOC() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        resolver.setDefaultInitialState(TOCState.PENDING);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        bool reverted = false;
        try registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "") {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on non-ACTIVE TOC");
    }

    // ============ Finalization Tests ============

    function test_RevertFinalizeBeforeDisputeWindow() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");

        // Try to finalize immediately (should fail)
        bool reverted = false;
        try registry.finalizeTOC(tocId) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert before dispute window passes");
    }

    // ============ Dispute Tests ============

    function test_DisputeTOC() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");

        // Dispute with proposed result (false)
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Incorrect outcome",
            "",    // evidenceURI
            TOCResultCodec.encodeBoolean(false) // proposedResult
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.DISPUTED_ROUND_1, "State should be DISPUTED");

        DisputeInfo memory info = registry.getDisputeInfo(tocId);
        require(info.disputer == address(this), "Disputer should be test contract");
        require(keccak256(bytes(info.reason)) == keccak256(bytes("Incorrect outcome")), "Reason should match");
        require(info.phase == DisputePhase.PRE_RESOLUTION, "Should be pre-resolution dispute");
    }

    function test_RevertDisputeAlreadyDisputed() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "First dispute",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        // Try to dispute again
        bool reverted = false;
        try registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Second dispute",
            "",
            TOCResultCodec.encodeBoolean(false)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on already disputed TOC");
    }

    // ============ Dispute Resolution Tests ============

    function test_ResolveDisputeUphold() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        // Create TOC with no pre-resolution dispute window, only post-resolution
        // This allows immediate resolution, then post-resolution dispute goes to admin
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,     // no pre-resolution dispute window
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,  // post-resolution disputes go to admin
            truthKeeper,
            address(0)
        );

        // Resolve immediately (no bond needed for undisputable pre-resolution)
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");

        // File post-resolution dispute (goes directly to admin for resolution)
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong outcome",
            "",    // evidenceURI
            TOCResultCodec.encodeBoolean(false) // Propose false as correct result
        );

        // Uphold dispute (admin action) - use admin's corrected answer
        registry.resolveDispute(
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeBoolean(false) // correctedResult
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.RESOLVED, "State should be RESOLVED");

        // Check boolean result was corrected (default was true, should now be false)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        require(result == false, "Result should be corrected to false");
    }

    function test_ResolveDisputeReject() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        // Create TOC with no pre-resolution dispute window, only post-resolution
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,     // no pre-resolution dispute
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");
        // Post-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong outcome",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        // Reject dispute (admin action)
        registry.resolveDispute(
            tocId,
            DisputeResolution.REJECT_DISPUTE,
            "" // Not used when rejecting
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.RESOLVED, "State should be RESOLVED");

        // Check boolean result is original (true)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        require(result == true, "Result should remain true");
    }

    function test_ResolveDisputeCancel() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        // Create TOC with no pre-resolution dispute window, only post-resolution
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,     // no pre-resolution dispute
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");
        // Post-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Invalid question",
            "",
            TOCResultCodec.encodeBoolean(false)
        );

        // Cancel TOC (admin action)
        registry.resolveDispute(
            tocId,
            DisputeResolution.CANCEL_TOC,
            "" // Not used when canceling
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.state == TOCState.CANCELLED, "State should be CANCELLED");
    }

    // ============ Answer Type Tests ============

    function test_NumericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(42);

        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.answerType == AnswerType.NUMERIC, "Answer type should be NUMERIC");
    }

    function test_GenericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.GENERIC);
        resolver.setDefaultResult(abi.encode("custom result"));

        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.answerType == AnswerType.GENERIC, "Answer type should be GENERIC");
    }

    // ============ View Function Tests ============

    function test_GetTOCInfo() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            abi.encode("test"),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOCInfo memory info = registry.getTOCInfo(tocId);
        require(info.resolver == address(resolver), "Resolver should match");
        require(info.state == TOCState.ACTIVE, "State should be ACTIVE");
        require(info.resolverTrust == ResolverTrust.RESOLVER, "Resolver trust should be RESOLVER");
        require(info.disputeWindow == DEFAULT_DISPUTE_WINDOW, "Dispute window should match");
        require(info.postResolutionWindow == DEFAULT_POST_RESOLUTION_WINDOW, "Post resolution window should match");
    }

    function test_GetTocQuestion() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        string memory question = registry.getTocQuestion(tocId);
        require(bytes(question).length > 0, "Question should not be empty");
    }

    function test_NextTocId() public {
        require(registry.nextTocId() == 1, "Initial nextTocId should be 1");

        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        registry.createTOC{value: 0.001 ether}(address(resolver), 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper, address(0));
        require(registry.nextTocId() == 2, "nextTocId should be 2 after creating one TOC");

        registry.createTOC{value: 0.001 ether}(address(resolver), 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper, address(0));
        require(registry.nextTocId() == 3, "nextTocId should be 3 after creating two TOCs");
    }

    function test_DefaultDisputeWindow() public {
        require(registry.defaultDisputeWindow() == 24 hours, "Default dispute window should be 24 hours");

        registry.setDefaultDisputeWindow(12 hours);
        require(registry.defaultDisputeWindow() == 12 hours, "Dispute window should be updated");
    }

    // ============ Bond Configuration Tests ============

    function test_BondValidation() public {
        // ETH bond should be acceptable
        bool ethAcceptable = registry.isAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND);
        require(ethAcceptable, "ETH bond should be acceptable");

        // Below minimum should not be acceptable
        bool belowMin = registry.isAcceptableResolutionBond(address(0), 0.01 ether);
        require(!belowMin, "Below minimum should not be acceptable");

        // Token bond should be acceptable
        bool tokenAcceptable = registry.isAcceptableResolutionBond(address(bondToken), MIN_RESOLUTION_BOND);
        require(tokenAcceptable, "Token bond should be acceptable");

        // Unknown token should not be acceptable
        bool unknownToken = registry.isAcceptableResolutionBond(address(0x123), MIN_RESOLUTION_BOND);
        require(!unknownToken, "Unknown token should not be acceptable");
    }

    // ============ Multiple TOCs Test ============

    function test_MultipleTOCs() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create multiple TOCs
        uint256 toc1 = registry.createTOC{value: 0.001 ether}(address(resolver), 0, abi.encode("toc1"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper, address(0));
        uint256 toc2 = registry.createTOC{value: 0.001 ether}(address(resolver), 1, abi.encode("toc2"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper, address(0));
        uint256 toc3 = registry.createTOC{value: 0.001 ether}(address(resolver), 2, abi.encode("toc3"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper, address(0));

        require(toc1 == 1, "First TOC should be ID 1");
        require(toc2 == 2, "Second TOC should be ID 2");
        require(toc3 == 3, "Third TOC should be ID 3");

        // Verify different answer types
        TOC memory tocData1 = registry.getTOC(toc1);
        TOC memory tocData2 = registry.getTOC(toc2);
        TOC memory tocData3 = registry.getTOC(toc3);

        require(tocData1.answerType == AnswerType.BOOLEAN, "TOC1 should be BOOLEAN");
        require(tocData2.answerType == AnswerType.NUMERIC, "TOC2 should be NUMERIC");
        require(tocData3.answerType == AnswerType.GENERIC, "TOC3 should be GENERIC");
    }

    // ============ Flexible Dispute Windows Tests ============

    function test_CreateTOCWithCustomDisputeWindows() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        uint256 customDisputeWindow = 12 hours;
        uint256 customPostResolutionWindow = 48 hours;

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            customDisputeWindow,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            customPostResolutionWindow,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.disputeWindow == customDisputeWindow, "Custom dispute window should be set");
        require(toc.postResolutionWindow == customPostResolutionWindow, "Custom post resolution window should be set");
    }

    function test_CreateUndisputableTOC() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create TOC with both windows = 0 (undisputable)
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,  // no pre-resolution dispute
            0,  // no TK window
            0,  // no escalation window
            0,  // no post-resolution dispute
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.disputeWindow == 0, "Dispute window should be 0");
        require(toc.postResolutionWindow == 0, "Post resolution window should be 0");
        require(toc.state == TOCState.ACTIVE, "State should be ACTIVE");
    }

    function test_ImmediateResolutionNoBond() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create undisputable TOC
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper,
            address(0)
        );

        // Resolve without bond (should work since undisputable)
        registry.resolveTOC(
            tocId,
            address(0),
            0,      // No bond required
            ""
        );

        TOC memory toc = registry.getTOC(tocId);
        // Should go directly to RESOLVED since disputeWindow = 0
        require(toc.state == TOCState.RESOLVED, "Undisputable TOC should go directly to RESOLVED");
    }

    function test_ImmediateResolutionWithPostResolutionWindow() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create TOC with no pre-resolution dispute but has post-resolution window
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,           // no pre-resolution dispute
            0,           // no TK window
            0,           // no escalation window
            24 hours,    // but has post-resolution dispute window
            truthKeeper,
            address(0)
        );

        // Resolve with bond (required since postResolutionWindow > 0)
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            ""
        );

        TOC memory toc = registry.getTOC(tocId);
        // Should go directly to RESOLVED since disputeWindow = 0
        require(toc.state == TOCState.RESOLVED, "Should go directly to RESOLVED when disputeWindow = 0");
        // But should have post-resolution dispute deadline set
        require(toc.postDisputeDeadline > block.timestamp, "Post dispute deadline should be set");
    }

    function test_FullyFinalizedWithoutPostResolutionWindow() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create undisputable TOC
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper,
            address(0)
        );

        // Resolve without bond
        registry.resolveTOC(tocId, address(0), 0, "");

        // Should be immediately fully finalized
        bool fullyFinalized = registry.isFullyFinalized(tocId);
        require(fullyFinalized, "Undisputable TOC should be fully finalized immediately");
    }

    function test_IsContestedAndHasCorrectedResult() public {
        // Create TOC with post-resolution window
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Pre-resolution = 0, post-resolution = 24h (immediate resolve, then can dispute)
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,           // immediate resolution
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            24 hours,    // post-resolution dispute window
            truthKeeper,
            address(0)
        );

        // Resolve immediately
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");

        // Initially not contested
        require(!registry.isContested(tocId), "Should not be contested initially");
        require(!registry.hasCorrectedResult(tocId), "Should not have corrected result initially");

        // File post-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Result is wrong",
            "",
            TOCResultCodec.encodeBoolean(false) // propose false as correct
        );

        // Now should be contested
        require(registry.isContested(tocId), "Should be contested after post-resolution dispute");

        // Uphold the dispute
        registry.resolveDispute(
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeBoolean(false) // correct to false
        );

        // Should have corrected result
        require(registry.hasCorrectedResult(tocId), "Should have corrected result after uphold");

        // Check corrected result
        bytes memory resultBytes = registry.getResult(tocId);
        bool correctedResult = TOCResultCodec.decodeBoolean(resultBytes);
        require(correctedResult == false, "Corrected result should be false");
    }

    function test_DisputeOnlyIfDisputeWindowGtZero() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create undisputable TOC (both windows = 0)
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper,
            address(0)
        );

        // Resolve
        registry.resolveTOC(tocId, address(0), 0, "");

        // Try to dispute - should fail
        bool reverted = false;
        try registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Should fail",
            "",
            TOCResultCodec.encodeBoolean(false)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should not be able to dispute undisputable TOC");
    }

    function test_DisputeInfoPhaseTracking() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Test pre-resolution dispute phase
        uint256 tocId1 = registry.createTOC{value: 0.001 ether}(
            address(resolver), 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper,
            address(0)
        );
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId1, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(tocId1, address(0), MIN_DISPUTE_BOND, "Pre-res dispute", "", TOCResultCodec.encodeBoolean(false));

        DisputeInfo memory info1 = registry.getDisputeInfo(tocId1);
        require(info1.phase == DisputePhase.PRE_RESOLUTION, "Should be pre-resolution phase");

        // Test post-resolution dispute phase
        uint256 tocId2 = registry.createTOC{value: 0.001 ether}(
            address(resolver), 0, "", 0, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper, address(0)  // immediate resolution, post-res window
        );
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId2, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(tocId2, address(0), MIN_DISPUTE_BOND, "Post-res dispute", "", TOCResultCodec.encodeBoolean(false));

        DisputeInfo memory info2 = registry.getDisputeInfo(tocId2);
        require(info2.phase == DisputePhase.POST_RESOLUTION, "Should be post-resolution phase");
    }

    function test_NumericDisputeWithProposedAndCorrectedResult() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(100);

        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create TOC with no pre-resolution dispute window, only post-resolution
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver), 0, "",
            0,     // no pre-resolution dispute
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");

        // Post-resolution dispute - proposes 50 as correct result
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong number",
            "",    // evidenceURI
            TOCResultCodec.encodeNumeric(50) // proposed numeric result
        );

        // Admin upholds with their own corrected value (75)
        registry.resolveDispute(
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            TOCResultCodec.encodeNumeric(75) // admin's corrected result (overrides disputer's 50)
        );

        bytes memory resultBytes = registry.getResult(tocId);
        int256 result = TOCResultCodec.decodeNumeric(resultBytes);
        require(result == 75, "Result should be admin's corrected value (75)");
    }

    // ============ ExtensiveResult Tests ============

    function test_GetExtensiveResult() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // undisputable for simplicity
            truthKeeper,
            address(0)
        );

        registry.resolveTOC(tocId, address(0), 0, "");

        ExtensiveResult memory result = registry.getExtensiveResult(tocId);
        require(result.answerType == AnswerType.BOOLEAN, "Answer type should be BOOLEAN");
        bool boolResult = TOCResultCodec.decodeBoolean(result.result);
        require(boolResult == true, "Boolean result should be true (mock default)");
        require(result.isFinalized == true, "Should be finalized");
        require(result.wasDisputed == false, "Should not be disputed");
        require(result.wasCorrected == false, "Should not be corrected");
        // TK approves by default, so tier is TK_GUARANTEED (not SYSTEM because resolver is RESOLVER)
        require(result.tier == AccountabilityTier.TK_GUARANTEED, "Tier should be TK_GUARANTEED when TK approves");
        require(result.resolverTrust == ResolverTrust.RESOLVER, "Resolver trust should be RESOLVER");
    }

    function test_GetExtensiveResultStrict() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create undisputable TOC
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper,
            address(0)
        );

        registry.resolveTOC(tocId, address(0), 0, "");

        // Should work for fully finalized TOC
        ExtensiveResult memory result = registry.getExtensiveResultStrict(tocId);
        require(result.isFinalized == true, "Should be finalized");
    }

    function test_GetExtensiveResultStrictReverts() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create TOC with post-resolution window (not immediately fully finalized)
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            0,           // no pre-resolution dispute
            0,           // no TK window
            0,           // no escalation window
            24 hours,    // post-resolution window - not fully finalized until this passes
            truthKeeper,
            address(0)
        );

        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(tocId, address(0), MIN_RESOLUTION_BOND, "");

        // Should revert - post-resolution window still open
        bool reverted = false;
        try registry.getExtensiveResultStrict(tocId) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when post-resolution window is still open");
    }

    function test_GetRegisteredResolvers() public {
        // Initially empty
        address[] memory resolvers = registry.getRegisteredResolvers();
        require(resolvers.length == 0, "Should have no resolvers initially");

        // Register resolver
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        resolvers = registry.getRegisteredResolvers();
        require(resolvers.length == 1, "Should have 1 resolver");
        require(resolvers[0] == address(resolver), "Resolver address should match");
    }

    // ============ TruthKeeper Approval Tests ============

    function test_TKApprovalGrantsTKGuaranteedTier() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Default TK approves all TOCs
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        // TK is whitelisted and approved, resolver is RESOLVER
        // So tier should be TK_GUARANTEED (not SYSTEM since resolver isn't SYSTEM)
        require(toc.tierAtCreation == AccountabilityTier.TK_GUARANTEED, "Tier should be TK_GUARANTEED when TK approves");

        // Verify TK was called
        require(truthKeeperContract.assignedTocs(tocId), "TK should have been notified of TOC");
    }

    function test_TKSoftRejectGivesPermissionlessTier() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Set TK to soft reject
        truthKeeperContract.setDefaultResponse(TKApprovalResponse.REJECT_SOFT);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.tierAtCreation == AccountabilityTier.RESOLVER, "Tier should be RESOLVER when TK soft rejects");
        require(toc.state == TOCState.ACTIVE, "TOC should still be created in ACTIVE state");
    }

    function test_TKHardRejectRevertsCreation() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Set TK to hard reject
        truthKeeperContract.setDefaultResponse(TKApprovalResponse.REJECT_HARD);

        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when TK hard rejects");
    }

    function test_TKApprovalWithSystemResolverGivesSystemTier() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        // TK is whitelisted and approves
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        require(toc.tierAtCreation == AccountabilityTier.SYSTEM, "Tier should be SYSTEM when SYSTEM resolver + whitelisted TK + approval");
    }

    function test_TKSoftRejectWithSystemResolverGivesPermissionless() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        // TK soft rejects
        truthKeeperContract.setDefaultResponse(TKApprovalResponse.REJECT_SOFT);

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        TOC memory toc = registry.getTOC(tocId);
        // Even with SYSTEM resolver, no approval = RESOLVER
        require(toc.tierAtCreation == AccountabilityTier.RESOLVER, "Tier should be RESOLVER when TK soft rejects");
    }

    function test_RevertCreateTOCWithEOATruthKeeper() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Try to use an EOA as TK (should fail)
        address eoaTK = address(0x999);

        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            eoaTK,
            address(0)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when using EOA as TruthKeeper");
    }

    function test_TKPerResolverFiltering() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        // Create another resolver
        MockResolver resolver2 = new MockResolver(address(registry));
        registry.registerResolver(address(resolver2));

        // TK approves resolver1 but rejects resolver2
        truthKeeperContract.setResolverResponse(address(resolver2), TKApprovalResponse.REJECT_HARD);

        // Should succeed with resolver1
        uint256 tocId1 = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );
        require(tocId1 == 1, "Should create TOC with resolver1");

        // Should fail with resolver2
        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver2),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when TK rejects resolver2");
    }

    // ============ Fee System Tests ============

    function test_CreationFeesCollected() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        bytes memory payload = abi.encode("test payload");
        uint256 totalFee = 0.001 ether; // protocol fee only (no resolver fee set)

        registry.createTOC{value: totalFee}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        // Check protocol balance (60% of 0.001 = 0.0006 ether)
        uint256 protocolBalance = registry.getProtocolBalance(FeeCategory.CREATION, address(0));
        require(protocolBalance == 0.0006 ether, "Protocol should get 60% of fee");

        // Check TK balance (40% of 0.001 = 0.0004 ether)
        uint256 tkBalance = registry.getTKBalance(truthKeeper, address(0));
        require(tkBalance == 0.0004 ether, "TK should get 40% of fee");
    }

    function test_WithdrawProtocolFees() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        registry.setTreasury(address(this));

        bytes memory payload = abi.encode("test payload");

        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        uint256 balanceBefore = address(this).balance;
        (uint256 creation, uint256 slashing) = registry.withdrawProtocolFees(address(0));

        require(creation == 0.0006 ether, "Creation fees should be 0.0006 ether");
        require(slashing == 0, "Slashing fees should be 0");
        require(address(this).balance == balanceBefore + creation, "Treasury should receive fees");
    }

    function test_RevertInsufficientFee() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        bytes memory payload = abi.encode("test payload");

        bool reverted = false;
        try registry.createTOC{value: 0.0001 ether}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert with insufficient fee");
    }

    function test_ExcessFeeRefunded() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);


        bytes memory payload = abi.encode("test payload");
        uint256 excessAmount = 0.01 ether;
        uint256 requiredFee = 0.001 ether;

        uint256 balanceBefore = address(this).balance;

        registry.createTOC{value: excessAmount}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        uint256 expectedBalance = balanceBefore - requiredFee;
        require(address(this).balance == expectedBalance, "Excess should be refunded");
    }

    function test_SlashingFeesDistributedToTK() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        registry.setTreasury(address(this));

        bytes memory payload = abi.encode("test payload");

        // Create TOC
        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        // Resolve and dispute
        resolver.setDefaultBooleanResult(true);
        registry.resolveTOC{value: MIN_RESOLUTION_BOND}(
            tocId,
            address(0),
            MIN_RESOLUTION_BOND,
            ""
        );

        // Dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            tocId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong answer",
            "",
            abi.encode(false)
        );

        // TK resolves dispute (uphold = slash proposer)
        truthKeeperContract.resolveDispute(
            address(registry),
            tocId,
            DisputeResolution.UPHOLD_DISPUTE,
            abi.encode(false)
        );

        // Skip escalation window
        vm.warp(block.timestamp + DEFAULT_ESCALATION_WINDOW + 1);

        // Finalize
        registry.finalizeAfterTruthKeeper(tocId);

        // Check slashing fees went to protocol and TK
        uint256 slashingBalance = registry.getProtocolBalance(FeeCategory.SLASHING, address(0));
        uint256 tkBalance = registry.getTKBalance(truthKeeper, address(0));

        // Half of resolution bond (0.05 ether) goes to contract
        // TK gets 40% of that = 0.02 ether
        // Protocol gets 60% = 0.03 ether
        require(slashingBalance == 0.03 ether, "Protocol should get 60% of slashed amount");

        // TK already had 0.0004 from creation, now adds 0.02
        require(tkBalance == 0.0004 ether + 0.02 ether, "TK should get 40% of slashed amount");
    }

    // ============ Multi-Token Fee Tests ============

    function test_MultiTokenFeesWithERC20() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.002 ether);
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(bondToken), 10e18);

        // Set min fee for ERC20
        registry.setMinFee(address(bondToken), 5e18);

        // Create TOC with ETH
        uint256 tocId1 = registry.createTOC{value: 0.002 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );
        require(tocId1 == 1, "First TOC should have ID 1");

        // Check ETH balance
        uint256 ethProtocolBalance = registry.getProtocolBalance(FeeCategory.CREATION, address(0));
        require(ethProtocolBalance > 0, "Protocol should have ETH balance");

        // Create TOC with ERC20
        bondToken.mint(address(this), 100e18);
        bondToken.approve(address(registry), 100e18);

        uint256 tocId2 = registry.createTOC(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(bondToken)
        );
        require(tocId2 == 2, "Second TOC should have ID 2");

        // Check ERC20 balance
        uint256 tokenProtocolBalance = registry.getProtocolBalance(FeeCategory.CREATION, address(bondToken));
        require(tokenProtocolBalance > 0, "Protocol should have ERC20 balance");
    }

    function test_ResolverFeeWithMaxSentinel() public {
        registry.registerResolver(address(resolver));

        // Set fee to MAX (meaning free)
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), type(uint256).max);

        // Get creation fee - should pay minimum since resolver is RESOLVER trust
        (uint256 protocolCut, uint256 resolverShare, uint256 total) =
            registry.getCreationFee(address(resolver), 0, address(0));

        require(resolverShare == 0, "Resolver share should be 0 for free template");
        require(protocolCut == 0.001 ether, "Protocol cut should be minimum fee");
        require(total == 0.001 ether, "Total should be minimum fee");
    }

    function test_SystemResolverExemptFromMinimum() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);

        // Set fee to MAX (free)
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), type(uint256).max);

        // Get creation fee - SYSTEM resolver should be exempt from minimum
        (uint256 protocolCut, uint256 resolverShare, uint256 total) =
            registry.getCreationFee(address(resolver), 0, address(0));

        require(protocolCut == 0, "Protocol cut should be 0 for SYSTEM resolver with free fee");
        require(resolverShare == 0, "Resolver share should be 0");
        require(total == 0, "Total should be 0");
    }

    function test_RevertTokenNotSupported() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        address unsupportedToken = address(0x999);

        bool reverted = false;
        try registry.createTOC(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            unsupportedToken
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert for unsupported token");
    }

    function test_RevertTokenNotSupportedByResolver() public {
        registry.registerResolver(address(resolver));
        // Only set ETH fee, not ERC20
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.001 ether);

        // Add bondToken to whitelist
        registry.setMinFee(address(bondToken), 5e18);

        bondToken.mint(address(this), 100e18);
        bondToken.approve(address(registry), 100e18);

        // Try to create TOC with ERC20 that resolver doesn't support
        bool reverted = false;
        try registry.createTOC(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(bondToken)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when resolver doesn't support token");
    }

    function test_ProtocolFeePercentByTrust() public {
        registry.registerResolver(address(resolver));

        // Set resolver to charge 0.01 ETH (high enough for percentages to matter)
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.01 ether);

        // RESOLVER trust (60%)
        (uint256 protocolCut1, , ) = registry.getCreationFee(address(resolver), 0, address(0));
        require(protocolCut1 == 0.006 ether, "RESOLVER should pay 60% protocol fee");

        // Upgrade to VERIFIED (40%)
        registry.setResolverTrust(address(resolver), ResolverTrust.VERIFIED);
        (uint256 protocolCut2, , ) = registry.getCreationFee(address(resolver), 0, address(0));
        require(protocolCut2 == 0.004 ether, "VERIFIED should pay 40% protocol fee");

        // Upgrade to SYSTEM (20%)
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);
        (uint256 protocolCut3, , ) = registry.getCreationFee(address(resolver), 0, address(0));
        require(protocolCut3 == 0.002 ether, "SYSTEM should pay 20% protocol fee");
    }

    function test_MinimumFeeAppliesWhenPercentageTooLow() public {
        registry.registerResolver(address(resolver));

        // Set resolver to charge only 0.0005 ETH (60% = 0.0003, less than min 0.001)
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.0005 ether);

        (uint256 protocolCut, uint256 resolverShare, uint256 total) =
            registry.getCreationFee(address(resolver), 0, address(0));

        // Protocol cut should be minimum (0.001), not percentage (0.0003)
        require(protocolCut == 0.001 ether, "Protocol cut should be minimum fee");
        // Resolver share is 0 because fee (0.0005) < protocolCut (0.001)
        require(resolverShare == 0, "Resolver should get nothing when fee < protocol cut");
        require(total == 0.001 ether, "Total should be minimum fee");
    }

    function test_TemplateFeeOverridesDefault() public {
        registry.registerResolver(address(resolver));

        // Set default fee
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.01 ether);

        // Set template-specific fee (lower)
        vm.prank(address(resolver));
        registry.setResolverFee(0, address(0), 0.005 ether);

        // Should use template fee
        uint256 fee = registry.getResolverFee(address(resolver), 0, address(0));
        require(fee == 0.005 ether, "Should use template fee");

        // Another template should use default
        uint256 defaultFee = registry.getResolverDefaultFee(address(resolver), address(0));
        require(defaultFee == 0.01 ether, "Default fee should be unchanged");
    }

    function test_SetMinFeeToZeroRemovesToken() public {
        // Add token to whitelist
        registry.setMinFee(address(bondToken), 5e18);
        require(registry.getMinFee(address(bondToken)) == 5e18, "Token should be whitelisted");

        // Remove token from whitelist
        registry.setMinFee(address(bondToken), 0);
        require(registry.getMinFee(address(bondToken)) == 0, "Token should be removed from whitelist");
    }

    function test_RevertInvalidFeePercent() public {
        bool reverted = false;
        try registry.setProtocolFeePercent(ResolverTrust.RESOLVER, 10001) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert for fee percent > 10000");
    }

    // ============ Multi-Token Withdrawal Tests ============

    function test_WithdrawProtocolFeesMultiToken() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.002 ether);
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(bondToken), 10e18);

        registry.setMinFee(address(bondToken), 5e18);
        registry.setTreasury(address(this));

        // Create TOC with ETH
        registry.createTOC{value: 0.002 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        // Create TOC with ERC20
        bondToken.mint(address(this), 100e18);
        bondToken.approve(address(registry), 100e18);
        registry.createTOC(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(bondToken)
        );

        // Withdraw ETH fees
        uint256 ethBalanceBefore = address(this).balance;
        (uint256 ethCreation, uint256 ethSlashing) = registry.withdrawProtocolFees(address(0));
        require(ethCreation > 0, "Should have ETH creation fees");
        require(ethSlashing == 0, "Should have no ETH slashing fees");
        require(address(this).balance == ethBalanceBefore + ethCreation, "Should receive ETH fees");

        // Withdraw ERC20 fees
        uint256 tokenBalanceBefore = bondToken.balanceOf(address(this));
        (uint256 tokenCreation, uint256 tokenSlashing) = registry.withdrawProtocolFees(address(bondToken));
        require(tokenCreation > 0, "Should have ERC20 creation fees");
        require(tokenSlashing == 0, "Should have no ERC20 slashing fees");
        require(bondToken.balanceOf(address(this)) == tokenBalanceBefore + tokenCreation, "Should receive ERC20 fees");
    }

    function test_WithdrawTKFeesMultiToken() public {
        registry.registerResolver(address(resolver));
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(0), 0.002 ether);
        vm.prank(address(resolver));
        registry.setResolverDefaultFee(address(bondToken), 10e18);

        registry.setMinFee(address(bondToken), 5e18);

        // Create TOC with ETH
        registry.createTOC{value: 0.002 ether}(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(0)
        );

        // Create TOC with ERC20
        bondToken.mint(address(this), 100e18);
        bondToken.approve(address(registry), 100e18);
        registry.createTOC(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper,
            address(bondToken)
        );

        // Check TK balances
        uint256 tkEthBalance = registry.getTKBalance(truthKeeper, address(0));
        uint256 tkTokenBalance = registry.getTKBalance(truthKeeper, address(bondToken));
        require(tkEthBalance > 0, "TK should have ETH balance");
        require(tkTokenBalance > 0, "TK should have ERC20 balance");

        // Withdraw TK ETH fees (as TK)
        uint256 tkEthBefore = address(truthKeeperContract).balance;
        truthKeeperContract.withdrawFees(address(registry), address(0));
        require(address(truthKeeperContract).balance == tkEthBefore + tkEthBalance, "TK should receive ETH");

        // Withdraw TK ERC20 fees (as TK)
        uint256 tkTokenBefore = bondToken.balanceOf(address(truthKeeperContract));
        truthKeeperContract.withdrawFees(address(registry), address(bondToken));
        require(bondToken.balanceOf(address(truthKeeperContract)) == tkTokenBefore + tkTokenBalance, "TK should receive ERC20");
    }

    // ============ Helpers ============

    receive() external payable {}
}
