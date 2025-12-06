// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "../Popregistry/POPRegistry.sol";
import "../Popregistry/POPTypes.sol";
import "./MockResolver.sol";
import "./MockERC20.sol";

/// @title POPRegistryTest
/// @notice Comprehensive tests for POPRegistry contract
contract POPRegistryTest {
    POPRegistry registry;
    MockResolver resolver;
    MockERC20 bondToken;

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
        truthKeeper = address(0x4);

        // Deploy registry
        registry = new POPRegistry();

        // Deploy mock resolver with registry address
        resolver = new MockResolver(address(registry));

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

    function test_RegisterSystemResolver() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        ResolverType resolverType = registry.getResolverType(address(resolver));
        require(resolverType == ResolverType.SYSTEM, "Resolver type should be SYSTEM");

        bool isApproved = registry.isApprovedResolver(ResolverType.SYSTEM, address(resolver));
        require(isApproved, "Resolver should be approved");

        uint256 count = registry.getResolverCount(ResolverType.SYSTEM);
        require(count == 1, "Should have 1 system resolver");
    }

    function test_RegisterPublicResolver() public {
        registry.registerResolver(ResolverType.PUBLIC, address(resolver));

        ResolverType resolverType = registry.getResolverType(address(resolver));
        require(resolverType == ResolverType.PUBLIC, "Resolver type should be PUBLIC");

        bool isApproved = registry.isApprovedResolver(ResolverType.PUBLIC, address(resolver));
        require(isApproved, "Resolver should be approved");
    }

    function test_RevertRegisterZeroAddress() public {
        bool reverted = false;
        try registry.registerResolver(ResolverType.SYSTEM, address(0)) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on zero address");
    }

    function test_RevertRegisterDuplicateResolver() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        bool reverted = false;
        try registry.registerResolver(ResolverType.PUBLIC, address(resolver)) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on duplicate registration");
    }

    function test_DeprecateAndRestoreResolver() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        // Deprecate
        registry.deprecateResolver(ResolverType.SYSTEM, address(resolver));
        require(registry.getResolverType(address(resolver)) == ResolverType.DEPRECATED, "Should be deprecated");

        // Restore as PUBLIC
        registry.restoreResolver(address(resolver), ResolverType.PUBLIC);
        require(registry.getResolverType(address(resolver)) == ResolverType.PUBLIC, "Should be restored as PUBLIC");
    }

    // ============ POP Creation Tests ============

    function test_CreatePOPWithSystemResolver() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        bytes memory payload = abi.encode("test payload");

        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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

    function test_CreatePOPWithPublicResolver() public {
        registry.registerResolver(ResolverType.PUBLIC, address(resolver));

        uint256 resolverId = registry.getResolverId(ResolverType.PUBLIC, address(resolver));
        bytes memory payload = abi.encode("test payload");

        uint256 popId = registry.createPOPWithPublicResolver(
            resolverId,
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );
        require(popId == 1, "First POP should have ID 1");
    }

    function test_CreatePOPWithPendingState() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        bool reverted = false;
        try registry.createPOPWithSystemResolver(
            resolverId,
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

    function test_RevertCreatePOPWithDeprecatedResolver() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        registry.deprecateResolver(ResolverType.SYSTEM, address(resolver));

        bool reverted = false;
        try registry.createPOPWithSystemResolver(
            resolverId,
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
        require(reverted, "Should revert on deprecated resolver");
    }

    // ============ POP Approval/Rejection Tests ============

    function test_ApproveAndRejectPOP() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
            0,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Resolver approves (we call from test contract, which is registry for mock)
        // Need to call from resolver - set test contract as registry temporarily
        resolver.setRegistry(address(this));

        // Can't easily test this without pranking - skip for now
    }

    // ============ Resolution Tests ============

    function test_ResolvePOPWithETHBond() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            false, // proposedBooleanResult
            0,     // proposedNumericResult
            ""     // proposedGenericResult
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.DISPUTED_ROUND_1, "State should be DISPUTED");

        DisputeInfo memory info = registry.getDisputeInfo(popId);
        require(info.disputer == address(this), "Disputer should be test contract");
        require(keccak256(bytes(info.reason)) == keccak256(bytes("Incorrect outcome")), "Reason should match");
        require(info.phase == DisputePhase.PRE_RESOLUTION, "Should be pre-resolution dispute");
    }

    function test_RevertDisputeAlreadyDisputed() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            "", false, 0, ""
        );

        // Try to dispute again
        bool reverted = false;
        try registry.dispute{value: MIN_DISPUTE_BOND}(
            popId,
            address(0),
            MIN_DISPUTE_BOND,
            "Second dispute",
            "", false, 0, ""
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on already disputed POP");
    }

    // ============ Dispute Resolution Tests ============

    function test_ResolveDisputeUphold() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        // Create POP with no pre-resolution dispute window, only post-resolution
        // This allows immediate resolution, then post-resolution dispute goes to admin
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            false, 0, "" // Propose false as correct result
        );

        // Uphold dispute (admin action) - use admin's corrected answer
        registry.resolveDispute(
            popId,
            DisputeResolution.UPHOLD_DISPUTE,
            false, // correctedBooleanResult
            0,     // correctedNumericResult
            ""     // correctedGenericResult
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVED, "State should be RESOLVED");

        // Check boolean result was corrected (default was true, should now be false)
        bool result = registry.getBooleanResult(popId);
        require(result == false, "Result should be corrected to false");
    }

    function test_ResolveDisputeReject() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        // Create POP with no pre-resolution dispute window, only post-resolution
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            "", false, 0, ""
        );

        // Reject dispute (admin action)
        registry.resolveDispute(
            popId,
            DisputeResolution.REJECT_DISPUTE,
            false, 0, "" // Not used when rejecting
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVED, "State should be RESOLVED");

        // Check boolean result is original (true)
        bool result = registry.getBooleanResult(popId);
        require(result == true, "Result should remain true");
    }

    function test_ResolveDisputeCancel() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        // Create POP with no pre-resolution dispute window, only post-resolution
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            "", false, 0, ""
        );

        // Cancel POP (admin action)
        registry.resolveDispute(
            popId,
            DisputeResolution.CANCEL_POP,
            false, 0, "" // Not used when canceling
        );

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.CANCELLED, "State should be CANCELLED");
    }

    // ============ Answer Type Tests ============

    function test_NumericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(42);

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        resolver.setDefaultGenericResult(abi.encode("custom result"));

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        require(info.resolverType == ResolverType.SYSTEM, "Resolver type should be SYSTEM");
        require(info.resolverId == resolverId, "Resolver ID should match");
        require(info.disputeWindow == DEFAULT_DISPUTE_WINDOW, "Dispute window should match");
        require(info.postResolutionWindow == DEFAULT_POST_RESOLUTION_WINDOW, "Post resolution window should match");
    }

    function test_GetPopQuestion() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        registry.createPOPWithSystemResolver(resolverId, 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        require(registry.nextPopId() == 2, "nextPopId should be 2 after creating one POP");

        registry.createPOPWithSystemResolver(resolverId, 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
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

    // ============ Resolver Config Tests ============

    function test_UpdateSystemResolverConfig() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        SystemResolverConfig memory newConfig = SystemResolverConfig({
            disputeWindow: 48 hours,
            isActive: true,
            registeredAt: block.timestamp,
            registeredBy: address(this)
        });

        registry.updateSystemResolverConfig(address(resolver), newConfig);

        SystemResolverConfig memory config = registry.getSystemResolverConfig(address(resolver));
        require(config.disputeWindow == 48 hours, "Dispute window should be updated");
    }

    function test_UpdatePublicResolverConfig() public {
        registry.registerResolver(ResolverType.PUBLIC, address(resolver));

        PublicResolverConfig memory newConfig = PublicResolverConfig({
            disputeWindow: 72 hours,
            isActive: true,
            registeredAt: block.timestamp,
            registeredBy: address(this)
        });

        registry.updatePublicResolverConfig(address(resolver), newConfig);

        PublicResolverConfig memory config = registry.getPublicResolverConfig(address(resolver));
        require(config.disputeWindow == 72 hours, "Dispute window should be updated");
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

    function test_RevertInvalidResolverId() public {
        bool reverted = false;
        try registry.getResolverAddress(ResolverType.SYSTEM, 999) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should revert on invalid resolver ID");
    }

    // ============ Multiple POPs Test ============

    function test_MultiplePOPs() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create multiple POPs
        uint256 pop1 = registry.createPOPWithSystemResolver(resolverId, 0, abi.encode("pop1"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        uint256 pop2 = registry.createPOPWithSystemResolver(resolverId, 1, abi.encode("pop2"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);
        uint256 pop3 = registry.createPOPWithSystemResolver(resolverId, 2, abi.encode("pop3"), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper);

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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        uint256 customDisputeWindow = 12 hours;
        uint256 customPostResolutionWindow = 48 hours;

        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create POP with both windows = 0 (undisputable)
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create undisputable POP
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create POP with no pre-resolution dispute but has post-resolution window
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create undisputable POP
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Pre-resolution = 0, post-resolution = 24h (immediate resolve, then can dispute)
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            "", false, 0, "" // evidenceURI, propose false as correct
        );

        // Now should be contested
        require(registry.isContested(popId), "Should be contested after post-resolution dispute");

        // Uphold the dispute
        registry.resolveDispute(
            popId,
            DisputeResolution.UPHOLD_DISPUTE,
            false, 0, "" // correct to false
        );

        // Should have corrected result
        require(registry.hasCorrectedResult(popId), "Should have corrected result after uphold");

        // Check corrected result
        bool correctedResult = registry.getCorrectedBooleanResult(popId);
        require(correctedResult == false, "Corrected result should be false");
    }

    function test_DisputeOnlyIfDisputeWindowGtZero() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create undisputable POP (both windows = 0)
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId,
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
            "", false, 0, ""
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        require(reverted, "Should not be able to dispute undisputable POP");
    }

    function test_DisputeInfoPhaseTracking() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Test pre-resolution dispute phase
        uint256 popId1 = registry.createPOPWithSystemResolver(
            resolverId, 0, "", DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper
        );
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId1, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId1, address(0), MIN_DISPUTE_BOND, "Pre-res dispute", "", false, 0, "");

        DisputeInfo memory info1 = registry.getDisputeInfo(popId1);
        require(info1.phase == DisputePhase.PRE_RESOLUTION, "Should be pre-resolution phase");

        // Test post-resolution dispute phase
        uint256 popId2 = registry.createPOPWithSystemResolver(
            resolverId, 0, "", 0, DEFAULT_TK_WINDOW, DEFAULT_ESCALATION_WINDOW, DEFAULT_POST_RESOLUTION_WINDOW, truthKeeper  // immediate resolution, post-res window
        );
        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId2, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId2, address(0), MIN_DISPUTE_BOND, "Post-res dispute", "", false, 0, "");

        DisputeInfo memory info2 = registry.getDisputeInfo(popId2);
        require(info2.phase == DisputePhase.POST_RESOLUTION, "Should be post-resolution phase");
    }

    function test_NumericDisputeWithProposedAndCorrectedResult() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(100);

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        // Create POP with no pre-resolution dispute window, only post-resolution
        uint256 popId = registry.createPOPWithSystemResolver(
            resolverId, 0, "",
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
            false,
            50,   // proposed numeric result
            ""
        );

        // Admin upholds with their own corrected value (75)
        registry.resolveDispute(
            popId,
            DisputeResolution.UPHOLD_DISPUTE,
            false,
            75,   // admin's corrected result (overrides disputer's 50)
            ""
        );

        int256 result = registry.getNumericResult(popId);
        require(result == 75, "Result should be admin's corrected value (75)");
    }

    // ============ Helpers ============

    receive() external payable {}
}
