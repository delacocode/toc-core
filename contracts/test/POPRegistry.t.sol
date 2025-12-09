// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "../Popregistry/POPRegistry.sol";
import "../Popregistry/POPTypes.sol";
import "./MockResolver.sol";
import "./MockERC20.sol";
import "./MockTruthKeeper.sol";
import "../libraries/POPResultCodec.sol";

/// @title POPRegistryTest
/// @notice Comprehensive tests for POPRegistry contract
contract POPRegistryTest {
    POPRegistry registry;
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
        registry = new POPRegistry();

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
    }

    // ============ Resolver Registration Tests ============

    function test_RegisterResolver() public {
        registry.registerResolver(address(resolver));

        ResolverTrust trust = registry.getResolverTrust(address(resolver));
        require(trust == ResolverTrust.PERMISSIONLESS, "Resolver trust should be PERMISSIONLESS");

        bool isRegistered = registry.isRegisteredResolver(address(resolver));
        require(isRegistered, "Resolver should be registered");

        uint256 count = registry.getResolverCount();
        require(count == 1, "Should have 1 resolver");
    }

    function test_SetResolverTrust() public {
        registry.registerResolver(address(resolver));

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

        ResolverConfig memory config = registry.getResolverConfig(address(resolver));
        require(config.trust == ResolverTrust.PERMISSIONLESS, "Trust should be PERMISSIONLESS");
        require(config.registeredAt > 0, "RegisteredAt should be set");
        require(config.registeredBy == address(this), "RegisteredBy should be test contract");
    }

    // ============ POP Creation Tests ============

    function test_CreatePOP() public {
        registry.registerResolver(address(resolver));

        bytes memory payload = abi.encode("test payload");

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );
        require(popId == 1, "First POP should have ID 1");

        POP memory pop = registry.getPOP(popId);
        require(pop.resolver == address(resolver), "Resolver should match");
        require(pop.state == POPState.ACTIVE, "State should be ACTIVE");
        require(pop.answerType == AnswerType.BOOLEAN, "Answer type should be BOOLEAN");
        require(pop.disputeWindow == DEFAULT_DISPUTE_WINDOW, "Dispute window should be set");
        require(pop.postResolutionWindow == DEFAULT_POST_RESOLUTION_WINDOW, "Post resolution window should be set");
        require(pop.truthKeeper == truthKeeper, "TruthKeeper should be set");
    }

    function test_CreatePOPWithSystemResolver() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);

        bytes memory payload = abi.encode("test payload");

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.tierAtCreation == AccountabilityTier.SYSTEM, "Tier should be SYSTEM for system resolver + whitelisted TK");
    }

    function test_CreatePOPWithPendingState() public {
        registry.registerResolver(address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.PENDING, "State should be PENDING");
    }

    function test_RevertCreatePOPWithInvalidTemplate() public {
        registry.registerResolver(address(resolver));

        bool reverted = false;
        try registry.createPOP(
            address(resolver),
            99,
            "",
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
        require(reverted, "Should revert on invalid template");
    }

    function test_RevertCreatePOPWithUnregisteredResolver() public {
        // Create another mock resolver but don't register it
        MockResolver unregisteredResolver = new MockResolver(address(registry));

        bool reverted = false;
        try registry.createPOP(
            address(unregisteredResolver),
            0,
            "",
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
        require(reverted, "Should revert on unregistered resolver");
    }

    // ============ POP Approval/Rejection Tests ============

    function test_ApproveAndRejectPOP() public {
        registry.registerResolver(address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.PENDING, "State should be PENDING");

        // Resolver approves (we call from test contract, which is registry for mock)
        // Need to call from resolver - set test contract as registry temporarily
        resolver.setRegistry(address(this));

        // Can't easily test this without pranking - skip for now
    }

    // ============ Resolution Tests ============

    function test_ResolvePOPWithETHBond() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Resolve with ETH bond
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(
            popId,
            address(0), // ETH
            MIN_RESOLUTION_BOND,
            ""
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVING, "State should be RESOLVING");
        require(pop.disputeDeadline > block.timestamp, "Dispute deadline should be set");

        ResolutionInfo memory info = registry.getResolutionInfo(popId);
        require(info.proposer == address(this), "Proposer should be test contract");
        require(info.bondAmount == MIN_RESOLUTION_BOND, "Bond amount should match");
    }

    function test_RevertResolveWithInsufficientBond() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        bool reverted = false;
        try registry.resolvePOP{value: 0.01 ether}(popId, address(0), 0.01 ether, "") {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on insufficient bond");
    }

    function test_RevertResolveNonActivePOP() public {
        registry.registerResolver(address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        bool reverted = false;
        try registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "") {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on non-ACTIVE POP");
    }

    // ============ Finalization Tests ============

    function test_RevertFinalizeBeforeDisputeWindow() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // Try to finalize immediately (should fail)
        bool reverted = false;
        try registry.finalizePOP(popId) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert before dispute window passes");
    }

    // ============ Dispute Tests ============

    function test_DisputePOP() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // Dispute with proposed result (false)
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Incorrect outcome",
            "",    // evidenceURI
            POPResultCodec.encodeBoolean(false) // proposedResult
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.DISPUTED_ROUND_1, "State should be DISPUTED");

        DisputeInfo memory info = registry.getDisputeInfo(popId);
        require(info.disputer == address(this), "Disputer should be test contract");
        require(keccak256(bytes(info.reason)) == keccak256(bytes("Incorrect outcome")), "Reason should match");
        require(info.phase == DisputePhase.PRE_RESOLUTION, "Should be pre-resolution dispute");
    }

    function test_RevertDisputeAlreadyDisputed() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "First dispute",
            "",
            POPResultCodec.encodeBoolean(false)
        );

        // Try to dispute again
        bool reverted = false;
        try registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Second dispute",
            "",
            POPResultCodec.encodeBoolean(false)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on already disputed POP");
    }

    // ============ Dispute Resolution Tests ============

    function test_ResolveDisputeUphold() public {
        registry.registerResolver(address(resolver));
        // Create POP with no pre-resolution dispute window, only post-resolution
        // This allows immediate resolution, then post-resolution dispute goes to admin
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,     // no pre-resolution dispute window
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,  // post-resolution disputes go to admin
            truthKeeper
        );

        // Resolve immediately (no bond needed for undisputable pre-resolution)
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // File post-resolution dispute (goes directly to admin for resolution)
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong outcome",
            "",    // evidenceURI
            POPResultCodec.encodeBoolean(false) // Propose false as correct result
        );

        // Uphold dispute (admin action) - use admin's corrected answer
        registry.resolveDispute(
            popId,
            DisputeResolution.UPHOLD_DISPUTE,
            POPResultCodec.encodeBoolean(false) // correctedResult
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVED, "State should be RESOLVED");

        // Check boolean result was corrected (default was true, should now be false)
        bytes memory resultBytes = registry.getResult(popId);
        bool result = POPResultCodec.decodeBoolean(resultBytes);
        require(result == false, "Result should be corrected to false");
    }

    function test_ResolveDisputeReject() public {
        registry.registerResolver(address(resolver));
        // Create POP with no pre-resolution dispute window, only post-resolution
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,     // no pre-resolution dispute
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        // Post-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong outcome",
            "",
            POPResultCodec.encodeBoolean(false)
        );

        // Reject dispute (admin action)
        registry.resolveDispute(
            popId,
            DisputeResolution.REJECT_DISPUTE,
            "" // Not used when rejecting
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVED, "State should be RESOLVED");

        // Check boolean result is original (true)
        bytes memory resultBytes = registry.getResult(popId);
        bool result = POPResultCodec.decodeBoolean(resultBytes);
        require(result == true, "Result should remain true");
    }

    function test_ResolveDisputeCancel() public {
        registry.registerResolver(address(resolver));
        // Create POP with no pre-resolution dispute window, only post-resolution
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,     // no pre-resolution dispute
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        // Post-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Invalid question",
            "",
            POPResultCodec.encodeBoolean(false)
        );

        // Cancel POP (admin action)
        registry.resolveDispute(
            popId,
            DisputeResolution.CANCEL_POP,
            "" // Not used when canceling
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.CANCELLED, "State should be CANCELLED");
    }

    // ============ Answer Type Tests ============

    function test_NumericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(42);

        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.answerType == AnswerType.NUMERIC, "Answer type should be NUMERIC");
    }

    function test_GenericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.GENERIC);
        resolver.setDefaultResult(abi.encode("custom result"));

        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.answerType == AnswerType.GENERIC, "Answer type should be GENERIC");
    }

    // ============ View Function Tests ============

    function test_GetPOPInfo() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            abi.encode("test"),
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POPInfo memory info = registry.getPOPInfo(popId);
        require(info.resolver == address(resolver), "Resolver should match");
        require(info.state == POPState.ACTIVE, "State should be ACTIVE");
        require(info.resolverTrust == ResolverTrust.PERMISSIONLESS, "Resolver trust should be PERMISSIONLESS");
        require(info.disputeWindow == DEFAULT_DISPUTE_WINDOW, "Dispute window should match");
        require(info.postResolutionWindow == DEFAULT_POST_RESOLUTION_WINDOW, "Post resolution window should match");
    }

    function test_GetPopQuestion() public {
        registry.registerResolver(address(resolver));
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        string memory question = registry.getPopQuestion(popId);
        require(bytes(question).length > 0, "Question should not be empty");
    }

    function test_NextPopId() public {
        require(registry.nextPopId() == 1, "Initial nextPopId should be 1");

        registry.registerResolver(address(resolver));

        registry.createPOP(address(resolver), 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        require(registry.nextPopId() == 2, "nextPopId should be 2 after creating one POP");

        registry.createPOP(address(resolver), 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        require(registry.nextPopId() == 3, "nextPopId should be 3 after creating two POPs");
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

    // ============ Edge Cases ============

    function test_RevertInvalidPopId() public {
        bool reverted = false;
        try registry.getPOPInfo(0) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on popId 0");

        reverted = false;
        try registry.getPOPInfo(999) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on non-existent popId");
    }

    // ============ Multiple POPs Test ============

    function test_MultiplePOPs() public {
        registry.registerResolver(address(resolver));

        // Create multiple POPs
        uint256 pop1 = registry.createPOP(address(resolver), 0, abi.encode("pop1"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        uint256 pop2 = registry.createPOP(address(resolver), 1, abi.encode("pop2"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        uint256 pop3 = registry.createPOP(address(resolver), 2, abi.encode("pop3"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);

        require(pop1 == 1, "First POP should be ID 1");
        require(pop2 == 2, "Second POP should be ID 2");
        require(pop3 == 3, "Third POP should be ID 3");

        // Verify different answer types
        POP memory popData1 = registry.getPOP(pop1);
        POP memory popData2 = registry.getPOP(pop2);
        POP memory popData3 = registry.getPOP(pop3);

        require(popData1.answerType == AnswerType.BOOLEAN, "POP1 should be BOOLEAN");
        require(popData2.answerType == AnswerType.NUMERIC, "POP2 should be NUMERIC");
        require(popData3.answerType == AnswerType.GENERIC, "POP3 should be GENERIC");
    }

    // ============ Flexible Dispute Windows Tests ============

    function test_CreatePOPWithCustomDisputeWindows() public {
        registry.registerResolver(address(resolver));

        uint256 customDisputeWindow = 12 hours;
        uint256 customPostResolutionWindow = 48 hours;

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            customDisputeWindow,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            customPostResolutionWindow,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.disputeWindow == customDisputeWindow, "Custom dispute window should be set");
        require(pop.postResolutionWindow == customPostResolutionWindow, "Custom post resolution window should be set");
    }

    function test_CreateUndisputablePOP() public {
        registry.registerResolver(address(resolver));

        // Create POP with both windows = 0 (undisputable)
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,  // no pre-resolution dispute
            0,  // no TK window
            0,  // no escalation window
            0,  // no post-resolution dispute
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.disputeWindow == 0, "Dispute window should be 0");
        require(pop.postResolutionWindow == 0, "Post resolution window should be 0");
        require(pop.state == POPState.ACTIVE, "State should be ACTIVE");
    }

    function test_ImmediateResolutionNoBond() public {
        registry.registerResolver(address(resolver));

        // Create undisputable POP
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper
        );

        // Resolve without bond (should work since undisputable)
        registry.resolvePOP(
            popId,
            address(0),
            0,      // No bond required
            ""
        );

        POP memory pop = registry.getPOP(popId);
        // Should go directly to RESOLVED since disputeWindow = 0
        require(pop.state == POPState.RESOLVED, "Undisputable POP should go directly to RESOLVED");
    }

    function test_ImmediateResolutionWithPostResolutionWindow() public {
        registry.registerResolver(address(resolver));

        // Create POP with no pre-resolution dispute but has post-resolution window
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,           // no pre-resolution dispute
            0,           // no TK window
            0,           // no escalation window
            24 hours,    // but has post-resolution dispute window
            truthKeeper
        );

        // Resolve with bond (required since postResolutionWindow > 0)
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(
            popId,
            address(0),
            MIN_RESOLUTION_BOND,
            ""
        );

        POP memory pop = registry.getPOP(popId);
        // Should go directly to RESOLVED since disputeWindow = 0
        require(pop.state == POPState.RESOLVED, "Should go directly to RESOLVED when disputeWindow = 0");
        // But should have post-resolution dispute deadline set
        require(pop.postDisputeDeadline > block.timestamp, "Post dispute deadline should be set");
    }

    function test_FullyFinalizedWithoutPostResolutionWindow() public {
        registry.registerResolver(address(resolver));

        // Create undisputable POP
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper
        );

        // Resolve without bond
        registry.resolvePOP(popId, address(0), 0, "");

        // Should be immediately fully finalized
        bool fullyFinalized = registry.isFullyFinalized(popId);
        require(fullyFinalized, "Undisputable POP should be fully finalized immediately");
    }

    function test_IsContestedAndHasCorrectedResult() public {
        // Create POP with post-resolution window
        registry.registerResolver(address(resolver));

        // Pre-resolution = 0, post-resolution = 24h (immediate resolve, then can dispute)
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,           // immediate resolution
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            24 hours,    // post-resolution dispute window
            truthKeeper
        );

        // Resolve immediately
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // Initially not contested
        require(!registry.isContested(popId), "Should not be contested initially");
        require(!registry.hasCorrectedResult(popId), "Should not have corrected result initially");

        // File post-resolution dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Result is wrong",
            "",
            POPResultCodec.encodeBoolean(false) // propose false as correct
        );

        // Now should be contested
        require(registry.isContested(popId), "Should be contested after post-resolution dispute");

        // Uphold the dispute
        registry.resolveDispute(
            popId,
            DisputeResolution.UPHOLD_DISPUTE,
            POPResultCodec.encodeBoolean(false) // correct to false
        );

        // Should have corrected result
        require(registry.hasCorrectedResult(popId), "Should have corrected result after uphold");

        // Check corrected result
        bytes memory resultBytes = registry.getResult(popId);
        bool correctedResult = POPResultCodec.decodeBoolean(resultBytes);
        require(correctedResult == false, "Corrected result should be false");
    }

    function test_DisputeOnlyIfDisputeWindowGtZero() public {
        registry.registerResolver(address(resolver));

        // Create undisputable POP (both windows = 0)
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper
        );

        // Resolve
        registry.resolvePOP(popId, address(0), 0, "");

        // Try to dispute - should fail
        bool reverted = false;
        try registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Should fail",
            "",
            POPResultCodec.encodeBoolean(false)
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should not be able to dispute undisputable POP");
    }

    function test_DisputeInfoPhaseTracking() public {
        registry.registerResolver(address(resolver));

        // Test pre-resolution dispute phase
        uint256 popId1 = registry.createPOP(
            address(resolver), 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper
        );
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId1, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId1, address(0), MIN_DISPUTE_BOND, "Pre-res dispute", "", POPResultCodec.encodeBoolean(false));

        DisputeInfo memory info1 = registry.getDisputeInfo(popId1);
        require(info1.phase == DisputePhase.PRE_RESOLUTION, "Should be pre-resolution phase");

        // Test post-resolution dispute phase
        uint256 popId2 = registry.createPOP(
            address(resolver), 0, "", 0, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper  // immediate resolution, post-res window
        );
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId2, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId2, address(0), MIN_DISPUTE_BOND, "Post-res dispute", "", POPResultCodec.encodeBoolean(false));

        DisputeInfo memory info2 = registry.getDisputeInfo(popId2);
        require(info2.phase == DisputePhase.POST_RESOLUTION, "Should be post-resolution phase");
    }

    function test_NumericDisputeWithProposedAndCorrectedResult() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(100);

        registry.registerResolver(address(resolver));

        // Create POP with no pre-resolution dispute window, only post-resolution
        uint256 popId = registry.createPOP(
            address(resolver), 0, "",
            0,     // no pre-resolution dispute
            0,     // no TK window
            0,     // no escalation window
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // Post-resolution dispute - proposes 50 as correct result
        registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Wrong number",
            "",    // evidenceURI
            POPResultCodec.encodeNumeric(50) // proposed numeric result
        );

        // Admin upholds with their own corrected value (75)
        registry.resolveDispute(
            popId,
            DisputeResolution.UPHOLD_DISPUTE,
            POPResultCodec.encodeNumeric(75) // admin's corrected result (overrides disputer's 50)
        );

        bytes memory resultBytes = registry.getResult(popId);
        int256 result = POPResultCodec.decodeNumeric(resultBytes);
        require(result == 75, "Result should be admin's corrected value (75)");
    }

    // ============ ExtensiveResult Tests ============

    function test_GetExtensiveResult() public {
        registry.registerResolver(address(resolver));

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // undisputable for simplicity
            truthKeeper
        );

        registry.resolvePOP(popId, address(0), 0, "");

        ExtensiveResult memory result = registry.getExtensiveResult(popId);
        require(result.answerType == AnswerType.BOOLEAN, "Answer type should be BOOLEAN");
        bool boolResult = POPResultCodec.decodeBoolean(result.result);
        require(boolResult == true, "Boolean result should be true (mock default)");
        require(result.isFinalized == true, "Should be finalized");
        require(result.wasDisputed == false, "Should not be disputed");
        require(result.wasCorrected == false, "Should not be corrected");
        // TK approves by default, so tier is TK_GUARANTEED (not SYSTEM because resolver is PERMISSIONLESS)
        require(result.tier == AccountabilityTier.TK_GUARANTEED, "Tier should be TK_GUARANTEED when TK approves");
        require(result.resolverTrust == ResolverTrust.PERMISSIONLESS, "Resolver trust should be PERMISSIONLESS");
    }

    function test_GetExtensiveResultStrict() public {
        registry.registerResolver(address(resolver));

        // Create undisputable POP
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0, 0, 0, 0,  // all windows = 0
            truthKeeper
        );

        registry.resolvePOP(popId, address(0), 0, "");

        // Should work for fully finalized POP
        ExtensiveResult memory result = registry.getExtensiveResultStrict(popId);
        require(result.isFinalized == true, "Should be finalized");
    }

    function test_GetExtensiveResultStrictReverts() public {
        registry.registerResolver(address(resolver));

        // Create POP with post-resolution window (not immediately fully finalized)
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            0,           // no pre-resolution dispute
            0,           // no TK window
            0,           // no escalation window
            24 hours,    // post-resolution window - not fully finalized until this passes
            truthKeeper
        );

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // Should revert - post-resolution window still open
        bool reverted = false;
        try registry.getExtensiveResultStrict(popId) {
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

        resolvers = registry.getRegisteredResolvers();
        require(resolvers.length == 1, "Should have 1 resolver");
        require(resolvers[0] == address(resolver), "Resolver address should match");
    }

    // ============ TruthKeeper Approval Tests ============

    function test_TKApprovalGrantsTKGuaranteedTier() public {
        registry.registerResolver(address(resolver));

        // Default TK approves all POPs
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        // TK is whitelisted and approved, resolver is PERMISSIONLESS
        // So tier should be TK_GUARANTEED (not SYSTEM since resolver isn't SYSTEM)
        require(pop.tierAtCreation == AccountabilityTier.TK_GUARANTEED, "Tier should be TK_GUARANTEED when TK approves");

        // Verify TK was called
        require(truthKeeperContract.assignedPops(popId), "TK should have been notified of POP");
    }

    function test_TKSoftRejectGivesPermissionlessTier() public {
        registry.registerResolver(address(resolver));

        // Set TK to soft reject
        truthKeeperContract.setDefaultResponse(TKApprovalResponse.REJECT_SOFT);

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.tierAtCreation == AccountabilityTier.PERMISSIONLESS, "Tier should be PERMISSIONLESS when TK soft rejects");
        require(pop.state == POPState.ACTIVE, "POP should still be created in ACTIVE state");
    }

    function test_TKHardRejectRevertsCreation() public {
        registry.registerResolver(address(resolver));

        // Set TK to hard reject
        truthKeeperContract.setDefaultResponse(TKApprovalResponse.REJECT_HARD);

        bool reverted = false;
        try registry.createPOP(
            address(resolver),
            0,
            "",
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
        require(reverted, "Should revert when TK hard rejects");
    }

    function test_TKApprovalWithSystemResolverGivesSystemTier() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);

        // TK is whitelisted and approves
        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.tierAtCreation == AccountabilityTier.SYSTEM, "Tier should be SYSTEM when SYSTEM resolver + whitelisted TK + approval");
    }

    function test_TKSoftRejectWithSystemResolverGivesPermissionless() public {
        registry.registerResolver(address(resolver));
        registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);

        // TK soft rejects
        truthKeeperContract.setDefaultResponse(TKApprovalResponse.REJECT_SOFT);

        uint256 popId = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        POP memory pop = registry.getPOP(popId);
        // Even with SYSTEM resolver, no approval = PERMISSIONLESS
        require(pop.tierAtCreation == AccountabilityTier.PERMISSIONLESS, "Tier should be PERMISSIONLESS when TK soft rejects");
    }

    function test_RevertCreatePOPWithEOATruthKeeper() public {
        registry.registerResolver(address(resolver));

        // Try to use an EOA as TK (should fail)
        address eoaTK = address(0x999);

        bool reverted = false;
        try registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            eoaTK
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert when using EOA as TruthKeeper");
    }

    function test_TKPerResolverFiltering() public {
        registry.registerResolver(address(resolver));

        // Create another resolver
        MockResolver resolver2 = new MockResolver(address(registry));
        registry.registerResolver(address(resolver2));

        // TK approves resolver1 but rejects resolver2
        truthKeeperContract.setResolverResponse(address(resolver2), TKApprovalResponse.REJECT_HARD);

        // Should succeed with resolver1
        uint256 popId1 = registry.createPOP(
            address(resolver),
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );
        require(popId1 == 1, "Should create POP with resolver1");

        // Should fail with resolver2
        bool reverted = false;
        try registry.createPOP(
            address(resolver2),
            0,
            "",
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
        require(reverted, "Should revert when TK rejects resolver2");
    }

    // ============ Helpers ============

    receive() external payable {}
}
