// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "contracts/SimpleTruthKeeper.sol";
import "contracts/TOCRegistry/TOCTypes.sol";

contract SimpleTruthKeeperTest is Test {
    SimpleTruthKeeper public tk;

    address public owner = address(0x1);
    address public registry = address(0x2);
    address public resolver1 = address(0x10);
    address public resolver2 = address(0x11);
    address public creator = address(0x20);

    uint32 public constant DEFAULT_DISPUTE_WINDOW = 1 hours;
    uint32 public constant DEFAULT_TK_WINDOW = 4 hours;

    function setUp() public {
        tk = new SimpleTruthKeeper(
            registry,
            owner,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsInitialState() public view {
        assertEq(tk.owner(), owner);
        assertEq(tk.registry(), registry);
        assertEq(tk.defaultMinDisputeWindow(), DEFAULT_DISPUTE_WINDOW);
        assertEq(tk.defaultMinTruthKeeperWindow(), DEFAULT_TK_WINDOW);
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(SimpleTruthKeeper.ZeroAddress.selector);
        new SimpleTruthKeeper(address(0), owner, DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(SimpleTruthKeeper.ZeroAddress.selector);
        new SimpleTruthKeeper(registry, address(0), DEFAULT_DISPUTE_WINDOW, DEFAULT_TK_WINDOW);
    }

    // ============ canAcceptToc Tests ============

    function test_canAcceptToc_rejectsSoftWhenResolverNotAllowed() public view {
        TKApprovalResponse response = tk.canAcceptToc(
            resolver1,
            0, // templateId
            creator,
            "", // payload
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            48 hours, // escalationWindow
            24 hours  // postResolutionWindow
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.REJECT_SOFT));
    }

    function test_canAcceptToc_approvesWhenAllConditionsMet() public {
        vm.prank(owner);
        tk.setResolverAllowed(resolver1, true);

        TKApprovalResponse response = tk.canAcceptToc(
            resolver1,
            0,
            creator,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            48 hours,
            24 hours
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.APPROVE));
    }

    function test_canAcceptToc_rejectsSoftWhenDisputeWindowTooShort() public {
        vm.prank(owner);
        tk.setResolverAllowed(resolver1, true);

        TKApprovalResponse response = tk.canAcceptToc(
            resolver1,
            0,
            creator,
            "",
            30 minutes, // Less than 1 hour minimum
            DEFAULT_TK_WINDOW,
            48 hours,
            24 hours
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.REJECT_SOFT));
    }

    function test_canAcceptToc_rejectsSoftWhenTkWindowTooShort() public {
        vm.prank(owner);
        tk.setResolverAllowed(resolver1, true);

        TKApprovalResponse response = tk.canAcceptToc(
            resolver1,
            0,
            creator,
            "",
            DEFAULT_DISPUTE_WINDOW,
            2 hours, // Less than 4 hour minimum
            48 hours,
            24 hours
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.REJECT_SOFT));
    }

    // ============ Per-Resolver Override Tests ============

    function test_canAcceptToc_usesResolverOverrideWindows() public {
        vm.startPrank(owner);
        tk.setResolverAllowed(resolver1, true);
        tk.setResolverMinWindows(resolver1, 30 minutes, 2 hours); // Lower than defaults
        vm.stopPrank();

        // Should approve with windows that meet override but not global default
        TKApprovalResponse response = tk.canAcceptToc(
            resolver1,
            0,
            creator,
            "",
            30 minutes, // Meets override, not global
            2 hours,    // Meets override, not global
            48 hours,
            24 hours
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.APPROVE));
    }

    function test_canAcceptToc_rejectsWhenBelowResolverOverride() public {
        vm.startPrank(owner);
        tk.setResolverAllowed(resolver1, true);
        tk.setResolverMinWindows(resolver1, 2 hours, 8 hours); // Higher than defaults
        vm.stopPrank();

        // Should reject even though it meets global defaults
        TKApprovalResponse response = tk.canAcceptToc(
            resolver1,
            0,
            creator,
            "",
            DEFAULT_DISPUTE_WINDOW, // 1 hour, less than 2 hour override
            DEFAULT_TK_WINDOW,      // 4 hours, less than 8 hour override
            48 hours,
            24 hours
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.REJECT_SOFT));
    }

    function test_getEffectiveMinWindows_returnsGlobalWhenNoOverride() public view {
        (uint32 minDispute, uint32 minTk) = tk.getEffectiveMinWindows(resolver1);
        assertEq(minDispute, DEFAULT_DISPUTE_WINDOW);
        assertEq(minTk, DEFAULT_TK_WINDOW);
    }

    function test_getEffectiveMinWindows_returnsOverrideWhenSet() public {
        vm.prank(owner);
        tk.setResolverMinWindows(resolver1, 2 hours, 8 hours);

        (uint32 minDispute, uint32 minTk) = tk.getEffectiveMinWindows(resolver1);
        assertEq(minDispute, 2 hours);
        assertEq(minTk, 8 hours);
    }

    // ============ Owner Function Tests ============

    function test_setDefaultMinWindows_updatesDefaults() public {
        vm.prank(owner);
        tk.setDefaultMinWindows(2 hours, 8 hours);

        assertEq(tk.defaultMinDisputeWindow(), 2 hours);
        assertEq(tk.defaultMinTruthKeeperWindow(), 8 hours);
    }

    function test_setDefaultMinWindows_revertsIfNotOwner() public {
        vm.prank(creator);
        vm.expectRevert(SimpleTruthKeeper.OnlyOwner.selector);
        tk.setDefaultMinWindows(2 hours, 8 hours);
    }

    function test_setResolversAllowed_batchAllows() public {
        address[] memory resolvers = new address[](2);
        resolvers[0] = resolver1;
        resolvers[1] = resolver2;

        vm.prank(owner);
        tk.setResolversAllowed(resolvers, true);

        assertTrue(tk.allowedResolvers(resolver1));
        assertTrue(tk.allowedResolvers(resolver2));
    }

    function test_setResolversAllowed_batchDisallows() public {
        address[] memory resolvers = new address[](2);
        resolvers[0] = resolver1;
        resolvers[1] = resolver2;

        vm.startPrank(owner);
        tk.setResolversAllowed(resolvers, true);
        tk.setResolversAllowed(resolvers, false);
        vm.stopPrank();

        assertFalse(tk.allowedResolvers(resolver1));
        assertFalse(tk.allowedResolvers(resolver2));
    }

    function test_setResolversAllowed_revertsIfNotOwner() public {
        address[] memory resolvers = new address[](1);
        resolvers[0] = resolver1;

        vm.prank(creator);
        vm.expectRevert(SimpleTruthKeeper.OnlyOwner.selector);
        tk.setResolversAllowed(resolvers, true);
    }

    function test_transferOwnership_transfersOwner() public {
        address newOwner = address(0x999);

        vm.prank(owner);
        tk.transferOwnership(newOwner);

        assertEq(tk.owner(), newOwner);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SimpleTruthKeeper.ZeroAddress.selector);
        tk.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsIfNotOwner() public {
        vm.prank(creator);
        vm.expectRevert(SimpleTruthKeeper.OnlyOwner.selector);
        tk.transferOwnership(creator);
    }

    function test_setRegistry_updatesRegistry() public {
        address newRegistry = address(0x888);

        vm.prank(owner);
        tk.setRegistry(newRegistry);

        assertEq(tk.registry(), newRegistry);
    }

    function test_setRegistry_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SimpleTruthKeeper.ZeroAddress.selector);
        tk.setRegistry(address(0));
    }
}
