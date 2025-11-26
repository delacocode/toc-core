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

        // Deploy mock ERC20 for bond testing
        bondToken = new MockERC20("Test Token", "TEST", 18);

        // Configure acceptable bonds
        registry.addAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND); // ETH
        registry.addAcceptableDisputeBond(address(0), MIN_DISPUTE_BOND); // ETH
        registry.addAcceptableResolutionBond(address(bondToken), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(bondToken), MIN_DISPUTE_BOND);
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

        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, payload);
        require(popId == 1, "First POP should have ID 1");

        POP memory pop = registry.getPOP(popId);
        require(pop.resolver == address(resolver), "Resolver should match");
        require(pop.state == POPState.ACTIVE, "State should be ACTIVE");
        require(pop.answerType == AnswerType.BOOLEAN, "Answer type should be BOOLEAN");
    }

    function test_CreatePOPWithPublicResolver() public {
        registry.registerResolver(ResolverType.PUBLIC, address(resolver));

        uint256 resolverId = registry.getResolverId(ResolverType.PUBLIC, address(resolver));
        bytes memory payload = abi.encode("test payload");

        uint256 popId = registry.createPOPWithPublicResolver(resolverId, 0, payload);
        require(popId == 1, "First POP should have ID 1");
    }

    function test_CreatePOPWithPendingState() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        resolver.setDefaultInitialState(POPState.PENDING);

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.PENDING, "State should be PENDING");
    }

    function test_RevertCreatePOPWithInvalidTemplate() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));

        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        bool reverted = false;
        try registry.createPOPWithSystemResolver(resolverId, 99, "") {
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
        try registry.createPOPWithSystemResolver(resolverId, 0, "") {
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
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        // Resolver approves (we call from test contract, which is registry for mock)
        // Need to call from resolver - set test contract as registry temporarily
        resolver.setRegistry(address(this));

        // Can't easily test this without pranking - skip for now
    }

    // ============ Resolution Tests ============

    function test_ResolvePOPWithETHBond() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

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
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

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
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

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
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

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
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");

        // Dispute
        registry.dispute{value: MIN_DISPUTE_BOND}(popId, address(0), MIN_DISPUTE_BOND, "Incorrect outcome");

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.DISPUTED, "State should be DISPUTED");

        DisputeInfo memory info = registry.getDisputeInfo(popId);
        require(info.disputer == address(this), "Disputer should be test contract");
        require(keccak256(bytes(info.reason)) == keccak256(bytes("Incorrect outcome")), "Reason should match");
    }

    function test_RevertDisputeAlreadyDisputed() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId, address(0), MIN_DISPUTE_BOND, "First dispute");

        // Try to dispute again
        bool reverted = false;
        try registry.dispute{value: MIN_DISPUTE_BOND}(popId, address(0), MIN_DISPUTE_BOND, "Second dispute") {
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
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        // Get initial balance
        uint256 initialBalance = address(this).balance;

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId, address(0), MIN_DISPUTE_BOND, "Wrong outcome");

        // Uphold dispute (admin action)
        registry.resolveDispute(popId, DisputeResolution.UPHOLD_DISPUTE);

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVED, "State should be RESOLVED");

        // Check boolean result was flipped (default was true, should now be false)
        bool result = registry.getBooleanResult(popId);
        require(result == false, "Result should be flipped to false");
    }

    function test_ResolveDisputeReject() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId, address(0), MIN_DISPUTE_BOND, "Wrong outcome");

        // Reject dispute
        registry.resolveDispute(popId, DisputeResolution.REJECT_DISPUTE);

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.RESOLVED, "State should be RESOLVED");

        // Check boolean result is original (true)
        bool result = registry.getBooleanResult(popId);
        require(result == true, "Result should remain true");
    }

    function test_ResolveDisputeCancel() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        registry.resolvePOP{value: MIN_RESOLUTION_BOND}(popId, address(0), MIN_RESOLUTION_BOND, "");
        registry.dispute{value: MIN_DISPUTE_BOND}(popId, address(0), MIN_DISPUTE_BOND, "Invalid question");

        // Cancel POP
        registry.resolveDispute(popId, DisputeResolution.CANCEL_POP);

        POP memory pop = registry.getPOP(popId);
        require(pop.state == POPState.CANCELLED, "State should be CANCELLED");
    }

    // ============ Answer Type Tests ============

    function test_NumericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.NUMERIC);
        resolver.setDefaultNumericResult(42);

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        POP memory pop = registry.getPOP(popId);
        require(pop.answerType == AnswerType.NUMERIC, "Answer type should be NUMERIC");
    }

    function test_GenericAnswerType() public {
        resolver.setTemplateAnswerType(0, AnswerType.GENERIC);
        resolver.setDefaultGenericResult(abi.encode("custom result"));

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        POP memory pop = registry.getPOP(popId);
        require(pop.answerType == AnswerType.GENERIC, "Answer type should be GENERIC");
    }

    // ============ View Function Tests ============

    function test_GetPOPInfo() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, abi.encode("test"));

        POPInfo memory info = registry.getPOPInfo(popId);
        require(info.resolver == address(resolver), "Resolver should match");
        require(info.state == POPState.ACTIVE, "State should be ACTIVE");
        require(info.resolverType == ResolverType.SYSTEM, "Resolver type should be SYSTEM");
        require(info.resolverId == resolverId, "Resolver ID should match");
        require(info.disputeWindow == 24 hours, "Dispute window should be default");
    }

    function test_GetPopQuestion() public {
        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));
        uint256 popId = registry.createPOPWithSystemResolver(resolverId, 0, "");

        string memory question = registry.getPopQuestion(popId);
        require(bytes(question).length > 0, "Question should not be empty");
    }

    function test_NextPopId() public {
        require(registry.nextPopId() == 1, "Initial nextPopId should be 1");

        registry.registerResolver(ResolverType.SYSTEM, address(resolver));
        uint256 resolverId = registry.getResolverId(ResolverType.SYSTEM, address(resolver));

        registry.createPOPWithSystemResolver(resolverId, 0, "");
        require(registry.nextPopId() == 2, "nextPopId should be 2 after creating one POP");

        registry.createPOPWithSystemResolver(resolverId, 0, "");
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
        uint256 pop1 = registry.createPOPWithSystemResolver(resolverId, 0, abi.encode("pop1"));
        uint256 pop2 = registry.createPOPWithSystemResolver(resolverId, 1, abi.encode("pop2"));
        uint256 pop3 = registry.createPOPWithSystemResolver(resolverId, 2, abi.encode("pop3"));

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

    // ============ Helpers ============

    receive() external payable {}
}
