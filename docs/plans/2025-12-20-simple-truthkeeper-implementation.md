# SimpleTruthKeeper Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a minimal TruthKeeper for initial launch with resolver allowlist and configurable time window validation.

**Architecture:** SimpleTruthKeeper uses a resolver allowlist plus time window minimums (global defaults with per-resolver overrides). Returns APPROVE only when all conditions are met, otherwise REJECT_SOFT. Single owner model.

**Tech Stack:** Solidity 0.8.29, Foundry for testing

---

### Task 1: Create SimpleTruthKeeper Contract Skeleton

**Files:**
- Create: `contracts/SimpleTruthKeeper.sol`

**Step 1: Create the contract file with storage and constructor**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ITruthKeeper} from "./TOCRegistry/ITruthKeeper.sol";
import {TKApprovalResponse} from "./TOCRegistry/TOCTypes.sol";

/// @title SimpleTruthKeeper
/// @notice Minimal TruthKeeper for initial launch with resolver allowlist and time window validation
/// @dev Returns APPROVE only when resolver is allowed AND time windows meet minimums
contract SimpleTruthKeeper is ITruthKeeper {
    // ============ State Variables ============

    address public owner;
    address public registry;

    // Global default minimums
    uint32 public defaultMinDisputeWindow;
    uint32 public defaultMinTruthKeeperWindow;

    // Resolver allowlist
    mapping(address => bool) public allowedResolvers;

    // Per-resolver time window overrides (0 = use global default)
    mapping(address => uint32) public resolverMinDisputeWindow;
    mapping(address => uint32) public resolverMinTruthKeeperWindow;

    // ============ Errors ============

    error OnlyOwner();
    error OnlyRegistry();
    error ZeroAddress();

    // ============ Events ============

    event ResolverAllowedChanged(address indexed resolver, bool allowed);
    event DefaultMinWindowsChanged(uint32 disputeWindow, uint32 tkWindow);
    event ResolverMinWindowsChanged(address indexed resolver, uint32 disputeWindow, uint32 tkWindow);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert OnlyRegistry();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _registry,
        address _owner,
        uint32 _defaultMinDisputeWindow,
        uint32 _defaultMinTruthKeeperWindow
    ) {
        if (_registry == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        registry = _registry;
        owner = _owner;
        defaultMinDisputeWindow = _defaultMinDisputeWindow;
        defaultMinTruthKeeperWindow = _defaultMinTruthKeeperWindow;
    }

    // Placeholder for ITruthKeeper - will implement in next task
    function canAcceptToc(
        address,
        uint32,
        address,
        bytes calldata,
        uint32,
        uint32,
        uint32,
        uint32
    ) external pure returns (TKApprovalResponse) {
        return TKApprovalResponse.REJECT_SOFT;
    }

    function onTocAssigned(
        uint256,
        address,
        uint32,
        address,
        bytes calldata,
        uint32,
        uint32,
        uint32,
        uint32
    ) external pure returns (TKApprovalResponse) {
        return TKApprovalResponse.REJECT_SOFT;
    }

    receive() external payable {}
}
```

**Step 2: Compile to verify syntax**

Run: `forge build`
Expected: Successful compilation

**Step 3: Commit**

```bash
git add contracts/SimpleTruthKeeper.sol
git commit -m "feat: add SimpleTruthKeeper contract skeleton"
```

---

### Task 2: Create Test File with First Test

**Files:**
- Create: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Write the test file with deployment test**

```solidity
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
```

**Step 2: Run tests to verify they pass**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All 3 tests PASS

**Step 3: Commit**

```bash
git add foundry-test/SimpleTruthKeeper.t.sol
git commit -m "test: add SimpleTruthKeeper constructor tests"
```

---

### Task 3: Implement Core Evaluation Logic

**Files:**
- Modify: `contracts/SimpleTruthKeeper.sol`
- Modify: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Write failing tests for canAcceptToc**

Add to test file:

```solidity
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
```

**Step 2: Run tests to verify they fail**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: New tests FAIL (setResolverAllowed doesn't exist yet)

**Step 3: Implement _evaluate and update canAcceptToc**

Replace the placeholder functions in `SimpleTruthKeeper.sol`:

```solidity
    // ============ ITruthKeeper Implementation ============

    /// @inheritdoc ITruthKeeper
    function canAcceptToc(
        address resolver,
        uint32 /* templateId */,
        address /* creator */,
        bytes calldata /* payload */,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external view returns (TKApprovalResponse) {
        return _evaluate(resolver, disputeWindow, truthKeeperWindow);
    }

    /// @inheritdoc ITruthKeeper
    function onTocAssigned(
        uint256 /* tocId */,
        address resolver,
        uint32 /* templateId */,
        address /* creator */,
        bytes calldata /* payload */,
        uint32 disputeWindow,
        uint32 truthKeeperWindow,
        uint32 /* escalationWindow */,
        uint32 /* postResolutionWindow */
    ) external onlyRegistry returns (TKApprovalResponse) {
        return _evaluate(resolver, disputeWindow, truthKeeperWindow);
    }

    // ============ Internal ============

    /// @notice Evaluate if a TOC should be approved
    /// @dev Returns APPROVE only if resolver is allowed AND time windows meet minimums
    function _evaluate(
        address resolver,
        uint32 disputeWindow,
        uint32 truthKeeperWindow
    ) internal view returns (TKApprovalResponse) {
        // Check resolver allowlist
        if (!allowedResolvers[resolver]) {
            return TKApprovalResponse.REJECT_SOFT;
        }

        // Get effective minimums (per-resolver override or global default)
        (uint32 minDispute, uint32 minTk) = getEffectiveMinWindows(resolver);

        // Check time windows
        if (disputeWindow < minDispute) {
            return TKApprovalResponse.REJECT_SOFT;
        }
        if (truthKeeperWindow < minTk) {
            return TKApprovalResponse.REJECT_SOFT;
        }

        return TKApprovalResponse.APPROVE;
    }

    // ============ View Helpers ============

    /// @notice Get effective minimum windows for a resolver
    /// @param resolver The resolver address
    /// @return minDisputeWindow The effective minimum dispute window
    /// @return minTkWindow The effective minimum TK window
    function getEffectiveMinWindows(address resolver)
        public
        view
        returns (uint32 minDisputeWindow, uint32 minTkWindow)
    {
        minDisputeWindow = resolverMinDisputeWindow[resolver];
        if (minDisputeWindow == 0) {
            minDisputeWindow = defaultMinDisputeWindow;
        }

        minTkWindow = resolverMinTruthKeeperWindow[resolver];
        if (minTkWindow == 0) {
            minTkWindow = defaultMinTruthKeeperWindow;
        }
    }

    /// @notice Check if a resolver is allowed
    /// @param resolver The resolver address
    /// @return allowed Whether the resolver is on the allowlist
    function isResolverAllowed(address resolver) external view returns (bool allowed) {
        return allowedResolvers[resolver];
    }

    // ============ Owner Functions ============

    /// @notice Add or remove a resolver from the allowlist
    /// @param resolver The resolver address
    /// @param allowed Whether to allow the resolver
    function setResolverAllowed(address resolver, bool allowed) external onlyOwner {
        allowedResolvers[resolver] = allowed;
        emit ResolverAllowedChanged(resolver, allowed);
    }
```

**Step 4: Run tests to verify they pass**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add contracts/SimpleTruthKeeper.sol foundry-test/SimpleTruthKeeper.t.sol
git commit -m "feat: implement SimpleTruthKeeper core evaluation logic"
```

---

### Task 4: Add Per-Resolver Time Window Overrides

**Files:**
- Modify: `contracts/SimpleTruthKeeper.sol`
- Modify: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Write failing tests for per-resolver overrides**

Add to test file:

```solidity
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
```

**Step 2: Run tests to verify they fail**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: Tests fail (setResolverMinWindows doesn't exist)

**Step 3: Implement setResolverMinWindows**

Add to `SimpleTruthKeeper.sol` in Owner Functions section:

```solidity
    /// @notice Set per-resolver minimum time windows
    /// @dev Set to 0 to use global defaults
    /// @param resolver The resolver address
    /// @param disputeWindow Minimum dispute window (0 = use default)
    /// @param tkWindow Minimum TK window (0 = use default)
    function setResolverMinWindows(
        address resolver,
        uint32 disputeWindow,
        uint32 tkWindow
    ) external onlyOwner {
        resolverMinDisputeWindow[resolver] = disputeWindow;
        resolverMinTruthKeeperWindow[resolver] = tkWindow;
        emit ResolverMinWindowsChanged(resolver, disputeWindow, tkWindow);
    }
```

**Step 4: Run tests to verify they pass**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add contracts/SimpleTruthKeeper.sol foundry-test/SimpleTruthKeeper.t.sol
git commit -m "feat: add per-resolver time window overrides"
```

---

### Task 5: Add Remaining Owner Functions

**Files:**
- Modify: `contracts/SimpleTruthKeeper.sol`
- Modify: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Write failing tests for owner functions**

Add to test file:

```solidity
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
```

**Step 2: Run tests to verify they fail**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: Tests fail (functions don't exist)

**Step 3: Implement remaining owner functions**

Add to `SimpleTruthKeeper.sol`:

```solidity
    /// @notice Set global default minimum windows
    /// @param disputeWindow Default minimum dispute window
    /// @param tkWindow Default minimum TK window
    function setDefaultMinWindows(uint32 disputeWindow, uint32 tkWindow) external onlyOwner {
        defaultMinDisputeWindow = disputeWindow;
        defaultMinTruthKeeperWindow = tkWindow;
        emit DefaultMinWindowsChanged(disputeWindow, tkWindow);
    }

    /// @notice Batch add or remove resolvers from the allowlist
    /// @param resolvers Array of resolver addresses
    /// @param allowed Whether to allow the resolvers
    function setResolversAllowed(address[] calldata resolvers, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < resolvers.length; i++) {
            allowedResolvers[resolvers[i]] = allowed;
            emit ResolverAllowedChanged(resolvers[i], allowed);
        }
    }

    /// @notice Transfer ownership to a new address
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Update registry address
    /// @param newRegistry The new registry address
    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        address oldRegistry = registry;
        registry = newRegistry;
        emit RegistryUpdated(oldRegistry, newRegistry);
    }
```

**Step 4: Run tests to verify they pass**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add contracts/SimpleTruthKeeper.sol foundry-test/SimpleTruthKeeper.t.sol
git commit -m "feat: add remaining SimpleTruthKeeper owner functions"
```

---

### Task 6: Test onTocAssigned and Registry Integration

**Files:**
- Modify: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Write tests for onTocAssigned**

Add to test file:

```solidity
    // ============ onTocAssigned Tests ============

    function test_onTocAssigned_approvesWhenCalledByRegistry() public {
        vm.prank(owner);
        tk.setResolverAllowed(resolver1, true);

        vm.prank(registry);
        TKApprovalResponse response = tk.onTocAssigned(
            1, // tocId
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

    function test_onTocAssigned_revertsWhenNotRegistry() public {
        vm.prank(owner);
        tk.setResolverAllowed(resolver1, true);

        vm.prank(creator); // Not registry
        vm.expectRevert(SimpleTruthKeeper.OnlyRegistry.selector);
        tk.onTocAssigned(
            1,
            resolver1,
            0,
            creator,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            48 hours,
            24 hours
        );
    }

    function test_onTocAssigned_rejectsSoftWhenNotAllowed() public {
        vm.prank(registry);
        TKApprovalResponse response = tk.onTocAssigned(
            1,
            resolver1, // Not allowed
            0,
            creator,
            "",
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            48 hours,
            24 hours
        );
        assertEq(uint8(response), uint8(TKApprovalResponse.REJECT_SOFT));
    }
```

**Step 2: Run tests to verify they pass**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add foundry-test/SimpleTruthKeeper.t.sol
git commit -m "test: add onTocAssigned tests for SimpleTruthKeeper"
```

---

### Task 7: Add Event Emission Tests

**Files:**
- Modify: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Write event tests**

Add to test file:

```solidity
    // ============ Event Tests ============

    event ResolverAllowedChanged(address indexed resolver, bool allowed);
    event DefaultMinWindowsChanged(uint32 disputeWindow, uint32 tkWindow);
    event ResolverMinWindowsChanged(address indexed resolver, uint32 disputeWindow, uint32 tkWindow);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    function test_setResolverAllowed_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ResolverAllowedChanged(resolver1, true);

        vm.prank(owner);
        tk.setResolverAllowed(resolver1, true);
    }

    function test_setDefaultMinWindows_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit DefaultMinWindowsChanged(2 hours, 8 hours);

        vm.prank(owner);
        tk.setDefaultMinWindows(2 hours, 8 hours);
    }

    function test_setResolverMinWindows_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ResolverMinWindowsChanged(resolver1, 2 hours, 8 hours);

        vm.prank(owner);
        tk.setResolverMinWindows(resolver1, 2 hours, 8 hours);
    }

    function test_transferOwnership_emitsEvent() public {
        address newOwner = address(0x999);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(owner);
        tk.transferOwnership(newOwner);
    }

    function test_setRegistry_emitsEvent() public {
        address newRegistry = address(0x888);

        vm.expectEmit(true, true, true, true);
        emit RegistryUpdated(registry, newRegistry);

        vm.prank(owner);
        tk.setRegistry(newRegistry);
    }
```

**Step 2: Run tests to verify they pass**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add foundry-test/SimpleTruthKeeper.t.sol
git commit -m "test: add event emission tests for SimpleTruthKeeper"
```

---

### Task 8: Final Cleanup and Full Test Run

**Files:**
- Review: `contracts/SimpleTruthKeeper.sol`
- Review: `foundry-test/SimpleTruthKeeper.t.sol`

**Step 1: Run all tests**

Run: `forge test --match-contract SimpleTruthKeeperTest -v`
Expected: All tests PASS

**Step 2: Run full test suite to ensure no regressions**

Run: `forge test`
Expected: All tests PASS

**Step 3: Final commit with complete contract**

```bash
git add .
git commit -m "feat: complete SimpleTruthKeeper implementation"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Contract skeleton | `contracts/SimpleTruthKeeper.sol` |
| 2 | Test file + constructor tests | `foundry-test/SimpleTruthKeeper.t.sol` |
| 3 | Core evaluation logic | Both files |
| 4 | Per-resolver overrides | Both files |
| 5 | Remaining owner functions | Both files |
| 6 | onTocAssigned tests | Test file |
| 7 | Event emission tests | Test file |
| 8 | Final cleanup | Both files |

Total: 8 tasks with ~20 tests covering all functionality.
