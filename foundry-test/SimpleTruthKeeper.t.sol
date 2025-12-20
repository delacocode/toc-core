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
}
