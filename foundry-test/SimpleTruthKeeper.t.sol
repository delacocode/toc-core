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
}
