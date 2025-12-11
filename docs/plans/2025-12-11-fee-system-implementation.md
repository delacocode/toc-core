# Fee System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a fee system for TOC creation with protocol fees, resolver fees, and TK revenue sharing.

**Architecture:** Add fee collection at `createTOC()`, split between protocol (by category), TK (aggregate), and resolver (per-TOC). Modify slashing to share protocol portion with TK. Add withdrawal functions for each party.

**Tech Stack:** Solidity 0.8.29, Foundry for testing

---

## Task 1: Add FeeCategory Enum to TOCTypes.sol

**Files:**
- Modify: `contracts/TOCRegistry/TOCTypes.sol`

**Step 1: Add FeeCategory enum after existing enums**

Add at the end of the file (before closing):

```solidity
/// @notice Categories of protocol fees for tracking
enum FeeCategory {
    CREATION,   // Fees from TOC creation
    SLASHING    // Fees from bond slashing
}
```

**Step 2: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/TOCTypes.sol
git commit -m "feat: add FeeCategory enum for fee tracking"
```

---

## Task 2: Rename PERMISSIONLESS to RESOLVER in TOCTypes.sol

**Files:**
- Modify: `contracts/TOCRegistry/TOCTypes.sol`

**Step 1: Update ResolverTrust enum**

Change:
```solidity
enum ResolverTrust {
    NONE,           // Not registered (default)
    PERMISSIONLESS, // Registered, no system guarantees
    VERIFIED,       // Admin reviewed, some assurance
    SYSTEM          // Full system backing
}
```

To:
```solidity
enum ResolverTrust {
    NONE,           // Not registered (default)
    RESOLVER,       // Registered, no system guarantees
    VERIFIED,       // Admin reviewed, some assurance
    SYSTEM          // Full system backing
}
```

**Step 2: Update AccountabilityTier enum**

Change:
```solidity
enum AccountabilityTier {
    NONE,           // Default/uninitialized
    PERMISSIONLESS, // No guarantees - creator's risk
    TK_GUARANTEED,  // TruthKeeper guarantees response
    SYSTEM          // System takes full accountability
}
```

To:
```solidity
enum AccountabilityTier {
    NONE,           // Default/uninitialized
    RESOLVER,       // No guarantees - creator's risk
    TK_GUARANTEED,  // TruthKeeper guarantees response
    SYSTEM          // System takes full accountability
}
```

**Step 3: Update all references in TOCRegistry.sol**

Replace all occurrences of:
- `ResolverTrust.PERMISSIONLESS` → `ResolverTrust.RESOLVER`
- `AccountabilityTier.PERMISSIONLESS` → `AccountabilityTier.RESOLVER`

**Step 4: Update all references in test files**

Check and update:
- `contracts/test/TOCRegistry.t.sol`
- `contracts/test/OptimisticResolver.t.sol`

**Step 5: Run tests to verify**

Run: `forge test`
Expected: All tests pass

**Step 6: Commit**

```bash
git add -A
git commit -m "refactor: rename PERMISSIONLESS to RESOLVER for clarity"
```

---

## Task 3: Add Fee Storage Variables to TOCRegistry.sol

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`

**Step 1: Add fee storage variables after existing state variables (around line 55)**

Add after `mapping(uint256 => EscalationInfo) private _escalations;`:

```solidity
    // ============ Fee System Storage ============

    // Protocol configuration
    address public treasury;
    uint256 public protocolFeeMinimum;      // Fee when TK == address(0) - NOT USED currently (TK required)
    uint256 public protocolFeeStandard;     // Fee when TK assigned

    // TK share percentages (basis points, e.g., 4000 = 40%)
    mapping(AccountabilityTier => uint256) public tkSharePercent;

    // Protocol balances by category
    mapping(FeeCategory => uint256) public protocolBalances;

    // TK balances (aggregate per TK)
    mapping(address => uint256) public tkBalances;

    // Resolver fees (per TOC)
    mapping(uint256 => uint256) public resolverFeeByToc;

    // Resolver fee configuration (per resolver, per template)
    mapping(address => mapping(uint32 => uint256)) public resolverTemplateFees;
```

**Step 2: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol
git commit -m "feat: add fee system storage variables"
```

---

## Task 4: Add Fee-Related Errors

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`

**Step 1: Add errors after existing errors (around line 91)**

Add after `error TruthKeeperRejected(address tk, uint256 tocId);`:

```solidity
    // Fee errors
    error TreasuryNotSet();
    error NotTreasury(address caller, address expected);
    error InsufficientFee(uint256 sent, uint256 required);
    error NoFeesToWithdraw();
    error NoResolverFee(uint256 tocId);
    error NotResolverForToc(address caller, uint256 tocId);
```

**Step 2: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol
git commit -m "feat: add fee-related error definitions"
```

---

## Task 5: Add Fee Events to ITOCRegistry.sol

**Files:**
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Add fee events after existing events (around line 94)**

Add after `event BondSlashed(...)`:

```solidity
    // Fee events
    event TreasurySet(address indexed treasury);
    event ProtocolFeeUpdated(uint256 minimum, uint256 standard);
    event TKShareUpdated(AccountabilityTier indexed tier, uint256 basisPoints);
    event ResolverFeeSet(address indexed resolver, uint32 indexed templateId, uint256 amount);
    event CreationFeesCollected(uint256 indexed tocId, uint256 protocolFee, uint256 tkFee, uint256 resolverFee);
    event SlashingFeesCollected(uint256 indexed tocId, uint256 protocolFee, uint256 tkFee);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 creationFees, uint256 slashingFees);
    event TKFeesWithdrawn(address indexed tk, uint256 amount);
    event ResolverFeeClaimed(address indexed resolver, uint256 indexed tocId, uint256 amount);
```

**Step 2: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add fee-related events to interface"
```

---

## Task 6: Add Fee Configuration Functions

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Add interface declarations to ITOCRegistry.sol**

Add in Admin Functions section (after `addAcceptableEscalationBond`):

```solidity
    /// @notice Set the treasury address for protocol fee withdrawals
    /// @param _treasury The treasury address
    function setTreasury(address _treasury) external;

    /// @notice Set the minimum protocol fee (when no TK or TK soft-rejects)
    /// @param amount Fee amount in wei
    function setProtocolFeeMinimum(uint256 amount) external;

    /// @notice Set the standard protocol fee (when TK approves)
    /// @param amount Fee amount in wei
    function setProtocolFeeStandard(uint256 amount) external;

    /// @notice Set TK share percentage for an accountability tier
    /// @param tier The accountability tier
    /// @param basisPoints Percentage in basis points (e.g., 4000 = 40%)
    function setTKSharePercent(AccountabilityTier tier, uint256 basisPoints) external;
```

**Step 2: Add implementations to TOCRegistry.sol**

Add after `addAcceptableEscalationBond` function (around line 215):

```solidity
    /// @inheritdoc ITOCRegistry
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /// @inheritdoc ITOCRegistry
    function setProtocolFeeMinimum(uint256 amount) external onlyOwner {
        protocolFeeMinimum = amount;
        emit ProtocolFeeUpdated(protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITOCRegistry
    function setProtocolFeeStandard(uint256 amount) external onlyOwner {
        protocolFeeStandard = amount;
        emit ProtocolFeeUpdated(protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITOCRegistry
    function setTKSharePercent(AccountabilityTier tier, uint256 basisPoints) external onlyOwner {
        require(basisPoints <= 10000, "Basis points cannot exceed 100%");
        tkSharePercent[tier] = basisPoints;
        emit TKShareUpdated(tier, basisPoints);
    }
```

**Step 3: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 4: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add fee configuration functions"
```

---

## Task 7: Add Resolver Fee Configuration

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Add interface declaration to ITOCRegistry.sol**

Add in a new "Resolver Fee Functions" section:

```solidity
    // ============ Resolver Fee Functions ============

    /// @notice Set resolver fee for a specific template
    /// @param templateId The template ID
    /// @param amount Fee amount in wei
    function setResolverFee(uint32 templateId, uint256 amount) external;

    /// @notice Get resolver fee for a specific resolver and template
    /// @param resolver The resolver address
    /// @param templateId The template ID
    /// @return amount The fee amount in wei
    function getResolverFee(address resolver, uint32 templateId) external view returns (uint256 amount);
```

**Step 2: Add implementation to TOCRegistry.sol**

Add after fee configuration functions:

```solidity
    // ============ Resolver Fee Functions ============

    /// @inheritdoc ITOCRegistry
    function setResolverFee(uint32 templateId, uint256 amount) external {
        // Caller must be a registered resolver
        if (_resolverConfigs[msg.sender].trust == ResolverTrust.NONE) {
            revert ResolverNotRegistered(msg.sender);
        }
        resolverTemplateFees[msg.sender][templateId] = amount;
        emit ResolverFeeSet(msg.sender, templateId, amount);
    }

    /// @inheritdoc ITOCRegistry
    function getResolverFee(address resolver, uint32 templateId) external view returns (uint256) {
        return resolverTemplateFees[resolver][templateId];
    }
```

**Step 3: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 4: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add resolver fee configuration"
```

---

## Task 8: Add getCreationFee View Function

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Add interface declaration to ITOCRegistry.sol**

Add to View Functions section:

```solidity
    /// @notice Get the total creation fee for a TOC
    /// @param resolver The resolver address
    /// @param templateId The template ID
    /// @return protocolFee The protocol fee portion
    /// @return resolverFee The resolver fee portion
    /// @return total The total fee required
    function getCreationFee(
        address resolver,
        uint32 templateId
    ) external view returns (uint256 protocolFee, uint256 resolverFee, uint256 total);
```

**Step 2: Add implementation to TOCRegistry.sol**

Add in view functions section:

```solidity
    /// @inheritdoc ITOCRegistry
    function getCreationFee(
        address resolver,
        uint32 templateId
    ) external view returns (uint256 protocolFee, uint256 resolverFee, uint256 total) {
        // Always use standard fee since TK is required
        protocolFee = protocolFeeStandard;
        resolverFee = resolverTemplateFees[resolver][templateId];
        total = protocolFee + resolverFee;
    }
```

**Step 3: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 4: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add getCreationFee view function"
```

---

## Task 9: Modify createTOC to Collect Fees

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Make createTOC payable in interface**

Change the function signature in ITOCRegistry.sol:

```solidity
    function createTOC(
        address resolver,
        uint32 templateId,
        bytes calldata payload,
        uint256 disputeWindow,
        uint256 truthKeeperWindow,
        uint256 escalationWindow,
        uint256 postResolutionWindow,
        address truthKeeper
    ) external payable returns (uint256 tocId);
```

**Step 2: Update createTOC implementation in TOCRegistry.sol**

Change function signature to `payable` and add fee collection logic after TK approval handling (around line 320):

Replace:
```solidity
        // Calculate tier with approval status
        toc.tierAtCreation = _calculateAccountabilityTier(resolver, truthKeeper, tkApproved);
```

With:
```solidity
        // Calculate tier with approval status
        toc.tierAtCreation = _calculateAccountabilityTier(resolver, truthKeeper, tkApproved);

        // Collect fees
        _collectCreationFees(tocId, resolver, templateId, truthKeeper, toc.tierAtCreation);
```

**Step 3: Add internal _collectCreationFees function**

Add in Internal Functions section:

```solidity
    /// @notice Collect creation fees and distribute to protocol, TK, and resolver
    function _collectCreationFees(
        uint256 tocId,
        address resolver,
        uint32 templateId,
        address tk,
        AccountabilityTier tier
    ) internal {
        uint256 protocolFee = protocolFeeStandard;
        uint256 resolverFee = resolverTemplateFees[resolver][templateId];
        uint256 totalFee = protocolFee + resolverFee;

        // Check sufficient payment
        if (msg.value < totalFee) {
            revert InsufficientFee(msg.value, totalFee);
        }

        // Calculate TK share from protocol fee
        uint256 tkShare = (protocolFee * tkSharePercent[tier]) / 10000;
        uint256 protocolKeeps = protocolFee - tkShare;

        // Store fees
        protocolBalances[FeeCategory.CREATION] += protocolKeeps;
        if (tkShare > 0) {
            tkBalances[tk] += tkShare;
        }
        if (resolverFee > 0) {
            resolverFeeByToc[tocId] = resolverFee;
        }

        // Refund excess
        if (msg.value > totalFee) {
            (bool success, ) = msg.sender.call{value: msg.value - totalFee}("");
            if (!success) revert TransferFailed();
        }

        emit CreationFeesCollected(tocId, protocolKeeps, tkShare, resolverFee);
    }
```

**Step 4: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 5: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: collect fees on TOC creation"
```

---

## Task 10: Modify _slashBondWithReward for TK Revenue Sharing

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`

**Step 1: Update _slashBondWithReward function**

Replace the existing function (around line 1105):

```solidity
    /// @notice Slash bond with 50% to winner, 50% to contract (shared with TK)
    function _slashBondWithReward(
        uint256 tocId,
        address winner,
        address loser,
        address token,
        uint256 amount
    ) internal {
        uint256 winnerShare = amount / 2;
        uint256 contractShare = amount - winnerShare; // Handles odd amounts

        // Transfer winner's share
        _transferBondOut(winner, token, winnerShare);

        // Split contract share with TK based on tier
        TOC storage toc = _tocs[tocId];
        uint256 tkShare = (contractShare * tkSharePercent[toc.tierAtCreation]) / 10000;
        uint256 protocolKeeps = contractShare - tkShare;

        // Store protocol portion
        protocolBalances[FeeCategory.SLASHING] += protocolKeeps;

        // Store TK portion (only if ETH - for now we only support ETH fees)
        if (tkShare > 0 && token == address(0)) {
            tkBalances[toc.truthKeeper] += tkShare;
        } else if (tkShare > 0) {
            // For non-ETH tokens, protocol keeps the TK share for now
            protocolBalances[FeeCategory.SLASHING] += tkShare;
        }

        emit SlashingFeesCollected(tocId, protocolKeeps, tkShare);
        emit BondSlashed(tocId, loser, token, contractShare);
    }
```

**Step 2: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol
git commit -m "feat: share slashing fees with TruthKeeper"
```

---

## Task 11: Add Withdrawal Functions

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Add interface declarations to ITOCRegistry.sol**

Add new section:

```solidity
    // ============ Fee Withdrawal Functions ============

    /// @notice Withdraw all protocol fees to treasury (treasury only)
    /// @return creationFees Amount of creation fees withdrawn
    /// @return slashingFees Amount of slashing fees withdrawn
    function withdrawProtocolFees() external returns (uint256 creationFees, uint256 slashingFees);

    /// @notice Withdraw protocol fees by category (treasury only)
    /// @param category The fee category to withdraw
    /// @return amount Amount withdrawn
    function withdrawProtocolFeesByCategory(FeeCategory category) external returns (uint256 amount);

    /// @notice Withdraw accumulated TK fees (called by TK)
    function withdrawTKFees() external;

    /// @notice Claim resolver fee for a specific TOC
    /// @param tocId The TOC ID
    function claimResolverFee(uint256 tocId) external;

    /// @notice Batch claim resolver fees for multiple TOCs
    /// @param tocIds Array of TOC IDs
    function claimResolverFees(uint256[] calldata tocIds) external;
```

**Step 2: Add modifier for treasury-only functions in TOCRegistry.sol**

Add after existing modifiers:

```solidity
    modifier onlyTreasury() {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (msg.sender != treasury) revert NotTreasury(msg.sender, treasury);
        _;
    }
```

**Step 3: Add implementations to TOCRegistry.sol**

Add new section for withdrawals:

```solidity
    // ============ Fee Withdrawal Functions ============

    /// @inheritdoc ITOCRegistry
    function withdrawProtocolFees() external onlyTreasury returns (uint256 creationFees, uint256 slashingFees) {
        creationFees = protocolBalances[FeeCategory.CREATION];
        slashingFees = protocolBalances[FeeCategory.SLASHING];

        uint256 total = creationFees + slashingFees;
        if (total == 0) revert NoFeesToWithdraw();

        protocolBalances[FeeCategory.CREATION] = 0;
        protocolBalances[FeeCategory.SLASHING] = 0;

        (bool success, ) = msg.sender.call{value: total}("");
        if (!success) revert TransferFailed();

        emit ProtocolFeesWithdrawn(msg.sender, creationFees, slashingFees);
    }

    /// @inheritdoc ITOCRegistry
    function withdrawProtocolFeesByCategory(FeeCategory category) external onlyTreasury returns (uint256 amount) {
        amount = protocolBalances[category];
        if (amount == 0) revert NoFeesToWithdraw();

        protocolBalances[category] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ProtocolFeesWithdrawn(
            msg.sender,
            category == FeeCategory.CREATION ? amount : 0,
            category == FeeCategory.SLASHING ? amount : 0
        );
    }

    /// @inheritdoc ITOCRegistry
    function withdrawTKFees() external {
        uint256 amount = tkBalances[msg.sender];
        if (amount == 0) revert NoFeesToWithdraw();

        tkBalances[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TKFeesWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc ITOCRegistry
    function claimResolverFee(uint256 tocId) external validTocId(tocId) {
        TOC storage toc = _tocs[tocId];
        if (msg.sender != toc.resolver) {
            revert NotResolverForToc(msg.sender, tocId);
        }

        uint256 amount = resolverFeeByToc[tocId];
        if (amount == 0) revert NoResolverFee(tocId);

        resolverFeeByToc[tocId] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ResolverFeeClaimed(msg.sender, tocId, amount);
    }

    /// @inheritdoc ITOCRegistry
    function claimResolverFees(uint256[] calldata tocIds) external {
        uint256 totalAmount = 0;
        address resolver = address(0);

        for (uint256 i = 0; i < tocIds.length; i++) {
            uint256 tocId = tocIds[i];
            if (tocId == 0 || tocId >= _nextTocId) continue;

            TOC storage toc = _tocs[tocId];

            // All TOCs must belong to same resolver
            if (resolver == address(0)) {
                resolver = toc.resolver;
            }
            if (msg.sender != toc.resolver) continue;

            uint256 amount = resolverFeeByToc[tocId];
            if (amount > 0) {
                resolverFeeByToc[tocId] = 0;
                totalAmount += amount;
                emit ResolverFeeClaimed(msg.sender, tocId, amount);
            }
        }

        if (totalAmount == 0) revert NoFeesToWithdraw();

        (bool success, ) = msg.sender.call{value: totalAmount}("");
        if (!success) revert TransferFailed();
    }
```

**Step 4: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 5: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add fee withdrawal functions"
```

---

## Task 12: Add Fee View Functions

**Files:**
- Modify: `contracts/TOCRegistry/TOCRegistry.sol`
- Modify: `contracts/TOCRegistry/ITOCRegistry.sol`

**Step 1: Add interface declarations to ITOCRegistry.sol**

Add to View Functions section:

```solidity
    /// @notice Get protocol fee configuration
    /// @return minimum The minimum protocol fee
    /// @return standard The standard protocol fee
    function getProtocolFees() external view returns (uint256 minimum, uint256 standard);

    /// @notice Get TK share percentage for a tier
    /// @param tier The accountability tier
    /// @return basisPoints The percentage in basis points
    function getTKSharePercent(AccountabilityTier tier) external view returns (uint256 basisPoints);

    /// @notice Get protocol balance by category
    /// @param category The fee category
    /// @return balance The balance in wei
    function getProtocolBalance(FeeCategory category) external view returns (uint256 balance);

    /// @notice Get TK balance
    /// @param tk The TruthKeeper address
    /// @return balance The balance in wei
    function getTKBalance(address tk) external view returns (uint256 balance);

    /// @notice Get resolver fee for a specific TOC
    /// @param tocId The TOC ID
    /// @return amount The fee amount in wei
    function getResolverFeeByToc(uint256 tocId) external view returns (uint256 amount);
```

**Step 2: Add implementations to TOCRegistry.sol**

Add in view functions section:

```solidity
    /// @inheritdoc ITOCRegistry
    function getProtocolFees() external view returns (uint256 minimum, uint256 standard) {
        return (protocolFeeMinimum, protocolFeeStandard);
    }

    /// @inheritdoc ITOCRegistry
    function getTKSharePercent(AccountabilityTier tier) external view returns (uint256) {
        return tkSharePercent[tier];
    }

    /// @inheritdoc ITOCRegistry
    function getProtocolBalance(FeeCategory category) external view returns (uint256) {
        return protocolBalances[category];
    }

    /// @inheritdoc ITOCRegistry
    function getTKBalance(address tk) external view returns (uint256) {
        return tkBalances[tk];
    }

    /// @inheritdoc ITOCRegistry
    function getResolverFeeByToc(uint256 tocId) external view returns (uint256) {
        return resolverFeeByToc[tocId];
    }
```

**Step 3: Run compilation to verify**

Run: `forge build`
Expected: Compilation successful

**Step 4: Commit**

```bash
git add contracts/TOCRegistry/TOCRegistry.sol contracts/TOCRegistry/ITOCRegistry.sol
git commit -m "feat: add fee view functions"
```

---

## Task 13: Update Existing Tests for Payable createTOC

**Files:**
- Modify: `contracts/test/TOCRegistry.t.sol`
- Modify: `contracts/test/OptimisticResolver.t.sol`

**Step 1: Update setUp in TOCRegistry.t.sol to configure fees**

Add after existing setup (after `registry.addWhitelistedTruthKeeper(truthKeeper);`):

```solidity
        // Configure fees
        registry.setProtocolFeeStandard(0.001 ether);
        registry.setTKSharePercent(AccountabilityTier.TK_GUARANTEED, 4000); // 40%
        registry.setTKSharePercent(AccountabilityTier.SYSTEM, 6000); // 60%
```

**Step 2: Update all createTOC calls to include value**

Search for all `registry.createTOC(` calls and add `{value: 0.001 ether}` modifier.

Example change:
```solidity
// Before
uint256 tocId = registry.createTOC(
    address(resolver),
    0,
    payload,
    ...
);

// After
uint256 tocId = registry.createTOC{value: 0.001 ether}(
    address(resolver),
    0,
    payload,
    ...
);
```

**Step 3: Update OptimisticResolver.t.sol similarly**

Add fee configuration in setUp and value to createTOC calls.

**Step 4: Run tests to verify**

Run: `forge test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add contracts/test/TOCRegistry.t.sol contracts/test/OptimisticResolver.t.sol
git commit -m "test: update tests for payable createTOC"
```

---

## Task 14: Add Fee System Tests

**Files:**
- Modify: `contracts/test/TOCRegistry.t.sol`

**Step 1: Add test for creation fee collection**

```solidity
    function test_CreationFeesCollected() public {
        registry.registerResolver(address(resolver));

        // Set resolver fee
        resolver.setResolverFee(0, 0.002 ether);

        bytes memory payload = abi.encode("test payload");
        uint256 totalFee = 0.001 ether + 0.002 ether; // protocol + resolver

        uint256 tocId = registry.createTOC{value: totalFee}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        // Check protocol balance (60% of 0.001 = 0.0006)
        uint256 protocolBalance = registry.getProtocolBalance(FeeCategory.CREATION);
        require(protocolBalance == 0.0006 ether, "Protocol should get 60% of fee");

        // Check TK balance (40% of 0.001 = 0.0004)
        uint256 tkBalance = registry.getTKBalance(truthKeeper);
        require(tkBalance == 0.0004 ether, "TK should get 40% of fee");

        // Check resolver fee stored
        uint256 resolverFee = registry.getResolverFeeByToc(tocId);
        require(resolverFee == 0.002 ether, "Resolver fee should be stored");
    }
```

**Step 2: Add test for fee withdrawal**

```solidity
    function test_WithdrawProtocolFees() public {
        registry.registerResolver(address(resolver));
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
            truthKeeper
        );

        uint256 balanceBefore = address(this).balance;
        (uint256 creation, uint256 slashing) = registry.withdrawProtocolFees();

        require(creation == 0.0006 ether, "Creation fees should be 0.0006 ether");
        require(slashing == 0, "Slashing fees should be 0");
        require(address(this).balance == balanceBefore + creation, "Treasury should receive fees");
    }

    // Add receive function to accept ETH
    receive() external payable {}
```

**Step 3: Add test for TK fee withdrawal**

```solidity
    function test_WithdrawTKFees() public {
        registry.registerResolver(address(resolver));

        bytes memory payload = abi.encode("test payload");

        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0,
            payload,
            DEFAULT_DISPUTE_WINDOW,
            DEFAULT_TK_WINDOW,
            DEFAULT_ESCALATION_WINDOW,
            DEFAULT_POST_RESOLUTION_WINDOW,
            truthKeeper
        );

        uint256 tkBalanceBefore = address(truthKeeperContract).balance;
        uint256 expectedTkFee = 0.0004 ether;

        // TK withdraws fees (call from TK contract)
        truthKeeperContract.withdrawFees(address(registry));

        require(
            address(truthKeeperContract).balance == tkBalanceBefore + expectedTkFee,
            "TK should receive fees"
        );
    }
```

**Step 4: Add helper function to MockTruthKeeper.sol**

Add to MockTruthKeeper:

```solidity
    function withdrawFees(address registryAddr) external {
        ITOCRegistry(registryAddr).withdrawTKFees();
    }

    receive() external payable {}
```

**Step 5: Run tests to verify**

Run: `forge test`
Expected: All tests pass

**Step 6: Commit**

```bash
git add contracts/test/TOCRegistry.t.sol contracts/test/MockTruthKeeper.sol
git commit -m "test: add fee system tests"
```

---

## Task 15: Add Test for Insufficient Fee Reverts

**Files:**
- Modify: `contracts/test/TOCRegistry.t.sol`

**Step 1: Add test for insufficient fee**

```solidity
    function test_RevertInsufficientFee() public {
        registry.registerResolver(address(resolver));

        bytes memory payload = abi.encode("test payload");

        bool reverted = false;
        try registry.createTOC{value: 0.0001 ether}( // Less than required
            address(resolver),
            0,
            payload,
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
        require(reverted, "Should revert with insufficient fee");
    }
```

**Step 2: Add test for excess fee refund**

```solidity
    function test_ExcessFeeRefunded() public {
        registry.registerResolver(address(resolver));

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
            truthKeeper
        );

        // Should have been refunded the excess
        uint256 expectedBalance = balanceBefore - requiredFee;
        require(address(this).balance == expectedBalance, "Excess should be refunded");
    }
```

**Step 3: Run tests to verify**

Run: `forge test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add contracts/test/TOCRegistry.t.sol
git commit -m "test: add fee edge case tests"
```

---

## Task 16: Add Test for Slashing Fee Distribution

**Files:**
- Modify: `contracts/test/TOCRegistry.t.sol`

**Step 1: Add test for slashing with TK share**

```solidity
    function test_SlashingFeesDistributedToTK() public {
        registry.registerResolver(address(resolver));
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
            truthKeeper
        );

        // Resolve and dispute
        resolver.setResolveResult(abi.encode(true));
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
        uint256 slashingBalance = registry.getProtocolBalance(FeeCategory.SLASHING);
        uint256 tkBalance = registry.getTKBalance(truthKeeper);

        // Half of resolution bond (0.05 ether) goes to contract
        // TK gets 40% of that = 0.02 ether
        // Protocol gets 60% = 0.03 ether
        require(slashingBalance == 0.03 ether, "Protocol should get 60% of slashed amount");

        // TK already had 0.0004 from creation, now adds 0.02
        require(tkBalance == 0.0004 ether + 0.02 ether, "TK should get 40% of slashed amount");
    }
```

**Step 2: Add helper to MockTruthKeeper**

Add to MockTruthKeeper.sol:

```solidity
    function resolveDispute(
        address registryAddr,
        uint256 tocId,
        DisputeResolution resolution,
        bytes calldata correctedResult
    ) external {
        ITOCRegistry(registryAddr).resolveTruthKeeperDispute(tocId, resolution, correctedResult);
    }
```

**Step 3: Run tests to verify**

Run: `forge test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add contracts/test/TOCRegistry.t.sol contracts/test/MockTruthKeeper.sol
git commit -m "test: add slashing fee distribution test"
```

---

## Task 17: Final Verification and Cleanup

**Step 1: Run full test suite**

Run: `forge test -vvv`
Expected: All tests pass with verbose output

**Step 2: Check for any compiler warnings**

Run: `forge build --force`
Expected: No warnings

**Step 3: Commit any final fixes**

```bash
git add -A
git commit -m "chore: final cleanup for fee system implementation"
```

---

## Summary

This implementation plan adds:

1. **Fee Categories**: CREATION and SLASHING for protocol revenue tracking
2. **Naming**: Renamed PERMISSIONLESS to RESOLVER throughout
3. **Storage**: Protocol balances, TK balances, resolver fees per TOC
4. **Configuration**: Protocol fees (minimum/standard), TK share percentages, resolver template fees
5. **Collection**: Fees collected at createTOC, distributed to protocol/TK/resolver
6. **Slashing**: Modified to share protocol portion with TK based on tier
7. **Withdrawals**: Treasury can withdraw protocol fees, TKs can withdraw their share, resolvers claim per-TOC
8. **Tests**: Comprehensive tests for fee collection, distribution, and withdrawal
