# Multi-Token Fee System Implementation Plan

## Overview

This plan implements the multi-token fee system as designed in `2025-12-12-multi-token-fee-design.md`.

---

## Task 1: Update Storage Variables

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Changes:**
1. Remove old storage:
   ```solidity
   // REMOVE
   uint256 public protocolFeeMinimum;
   uint256 public protocolFeeStandard;
   mapping(FeeCategory => uint256) public protocolBalances;
   mapping(address => uint256) public tkBalances;
   mapping(address => mapping(uint32 => uint256)) public resolverTemplateFees;
   ```

2. Add new storage:
   ```solidity
   // Token minimum fees (also serves as whitelist - value > 0 means supported)
   mapping(address => uint256) public minFeeByToken;

   // Protocol fee percentage by resolver trust (basis points)
   mapping(ResolverTrust => uint256) public protocolFeePercent;

   // Resolver default fees per token
   mapping(address => mapping(address => uint256)) public resolverDefaultFee;

   // Resolver template fees per token
   mapping(address => mapping(uint32 => mapping(address => uint256))) public resolverTemplateFees;

   // Protocol balances by category by token
   mapping(FeeCategory => mapping(address => uint256)) public protocolBalances;

   // TK balances by token
   mapping(address => mapping(address => uint256)) public tkBalances;

   // Resolver fee token per TOC
   mapping(uint256 => address) public resolverFeeTokenByToc;
   ```

**Verification:** Contract compiles (may have errors until other tasks complete)

---

## Task 2: Add New Errors

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Add:**
```solidity
error TokenNotSupported(address token);
error TokenNotSupportedByResolver(address resolver, address token);
error InvalidFeePercent(uint256 basisPoints);
```

**Verification:** Contract compiles

---

## Task 3: Update Events

**File:** `contracts/TOCRegistry/ITOCRegistry.sol`

**Update events:**
```solidity
// Replace ProtocolFeeUpdated
event MinFeeSet(address indexed token, uint256 amount);
event ProtocolFeePercentSet(ResolverTrust indexed trust, uint256 basisPoints);

// Replace ResolverFeeSet
event ResolverDefaultFeeSet(address indexed resolver, address indexed token, uint256 amount);
event ResolverFeeSet(address indexed resolver, uint32 indexed templateId, address indexed token, uint256 amount);

// Update CreationFeesCollected (add token)
event CreationFeesCollected(
    uint256 indexed tocId,
    address indexed token,
    uint256 protocolFee,
    uint256 tkFee,
    uint256 resolverFee
);

// Update SlashingFeesCollected (add token)
event SlashingFeesCollected(
    uint256 indexed tocId,
    address indexed token,
    uint256 protocolFee,
    uint256 tkFee
);

// Update withdrawal events (add token)
event ProtocolFeesWithdrawn(address indexed treasury, address indexed token, uint256 creationFees, uint256 slashingFees);
event TKFeesWithdrawn(address indexed tk, address indexed token, uint256 amount);
event ResolverFeeClaimed(address indexed resolver, uint256 indexed tocId, address indexed token, uint256 amount);
```

**Verification:** Contract compiles

---

## Task 4: Add Admin Configuration Functions

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Replace/Add:**
```solidity
/// @notice Set minimum fee for a token (also adds/removes from whitelist)
/// @param token Token address (address(0) for ETH)
/// @param amount Minimum fee (0 to remove from whitelist)
function setMinFee(address token, uint256 amount) external onlyOwner nonReentrant {
    minFeeByToken[token] = amount;
    emit MinFeeSet(token, amount);
}

/// @notice Set protocol fee percentage for a resolver trust level
/// @param trust The resolver trust level
/// @param basisPoints Percentage in basis points (e.g., 4000 = 40%)
function setProtocolFeePercent(ResolverTrust trust, uint256 basisPoints) external onlyOwner nonReentrant {
    if (basisPoints > 10000) revert InvalidFeePercent(basisPoints);
    protocolFeePercent[trust] = basisPoints;
    emit ProtocolFeePercentSet(trust, basisPoints);
}
```

**Remove:**
- `setProtocolFeeMinimum`
- `setProtocolFeeStandard`

**Verification:** Functions compile, can be called by owner

---

## Task 5: Add Resolver Fee Configuration Functions

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Replace/Add:**
```solidity
/// @notice Set default fee for a token (resolver calls this)
/// @param token Token address
/// @param amount Fee amount (0 = unset, MAX = free)
function setResolverDefaultFee(address token, uint256 amount) external nonReentrant {
    if (_resolverConfigs[msg.sender].trust == ResolverTrust.NONE) {
        revert ResolverNotRegistered(msg.sender);
    }
    resolverDefaultFee[msg.sender][token] = amount;
    emit ResolverDefaultFeeSet(msg.sender, token, amount);
}

/// @notice Set fee for specific template + token (resolver calls this)
/// @param templateId Template ID
/// @param token Token address
/// @param amount Fee amount (0 = unset/use default, MAX = free)
function setResolverFee(uint32 templateId, address token, uint256 amount) external nonReentrant {
    if (_resolverConfigs[msg.sender].trust == ResolverTrust.NONE) {
        revert ResolverNotRegistered(msg.sender);
    }
    resolverTemplateFees[msg.sender][templateId][token] = amount;
    emit ResolverFeeSet(msg.sender, templateId, token, amount);
}
```

**Verification:** Functions compile, resolver can set fees

---

## Task 6: Add Internal Resolver Fee Lookup

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Add:**
```solidity
/// @notice Get resolver fee for a template + token, following lookup order
/// @dev Returns 0 for MAX sentinel, reverts if token not supported by resolver
function _getResolverFee(
    address resolver,
    uint32 templateId,
    address token
) internal view returns (uint256) {
    // Check template-specific fee first
    uint256 templateFee = resolverTemplateFees[resolver][templateId][token];
    if (templateFee != 0) {
        // MAX means free
        return templateFee == type(uint256).max ? 0 : templateFee;
    }

    // Fall back to default fee
    uint256 defaultFee = resolverDefaultFee[resolver][token];
    if (defaultFee != 0) {
        return defaultFee == type(uint256).max ? 0 : defaultFee;
    }

    // No fee set = resolver doesn't support this token
    revert TokenNotSupportedByResolver(resolver, token);
}
```

**Verification:** Function compiles

---

## Task 7: Update _collectCreationFees

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Replace:**
```solidity
/// @notice Collect creation fees and distribute to protocol, TK, and resolver
function _collectCreationFees(
    uint256 tocId,
    address resolver,
    uint32 templateId,
    address tk,
    AccountabilityTier tier,
    address token
) internal {
    // Validate token is supported
    uint256 minFee = minFeeByToken[token];
    if (minFee == 0) revert TokenNotSupported(token);

    // Get resolver fee (reverts if resolver doesn't support token)
    uint256 resolverFee = _getResolverFee(resolver, templateId, token);

    // Calculate protocol cut
    ResolverTrust trust = _resolverConfigs[resolver].trust;
    uint256 percentageCut = (resolverFee * protocolFeePercent[trust]) / 10000;

    uint256 protocolCut;
    if (trust == ResolverTrust.SYSTEM) {
        // SYSTEM resolvers exempt from minimum
        protocolCut = percentageCut;
    } else {
        // Others pay at least minimum
        protocolCut = percentageCut > minFee ? percentageCut : minFee;
    }

    // Calculate splits
    uint256 resolverShare = resolverFee > protocolCut ? resolverFee - protocolCut : 0;
    uint256 tkShare = (protocolCut * tkSharePercent[tier]) / 10000;
    uint256 protocolKeeps = protocolCut - tkShare;

    // Total to collect
    uint256 totalFee = protocolCut + resolverShare;

    // Transfer in
    if (token == address(0)) {
        // ETH
        if (msg.value < totalFee) revert InsufficientFee(msg.value, totalFee);
    } else {
        // ERC20
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalFee);
    }

    // Store balances
    protocolBalances[FeeCategory.CREATION][token] += protocolKeeps;
    if (tkShare > 0) {
        tkBalances[tk][token] += tkShare;
    }
    if (resolverShare > 0) {
        resolverFeeByToc[tocId] = resolverShare;
        resolverFeeTokenByToc[tocId] = token;
    }

    // Refund excess ETH
    if (token == address(0) && msg.value > totalFee) {
        (bool success, ) = msg.sender.call{value: msg.value - totalFee}("");
        if (!success) revert TransferFailed();
    }

    emit CreationFeesCollected(tocId, token, protocolKeeps, tkShare, resolverShare);
}
```

**Verification:** Function compiles

---

## Task 8: Update createTOC

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Changes:**
1. Add `token` parameter to `createTOC`
2. Pass token to `_collectCreationFees`

```solidity
function createTOC(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper,
    address feeToken  // NEW PARAMETER
) external payable nonReentrant returns (uint256 tocId) {
    // ... existing validation ...

    // Calculate tier with approval status
    toc.tierAtCreation = _calculateAccountabilityTier(resolver, truthKeeper, tkApproved);

    // Collect fees (updated call)
    _collectCreationFees(tocId, resolver, templateId, truthKeeper, toc.tierAtCreation, feeToken);

    // ... rest of function ...
}
```

**Verification:** Function compiles

---

## Task 9: Update ITOCRegistry Interface

**File:** `contracts/TOCRegistry/ITOCRegistry.sol`

**Update function signatures:**
```solidity
function createTOC(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper,
    address feeToken
) external payable returns (uint256 tocId);

function setMinFee(address token, uint256 amount) external;
function setProtocolFeePercent(ResolverTrust trust, uint256 basisPoints) external;
function setResolverDefaultFee(address token, uint256 amount) external;
function setResolverFee(uint32 templateId, address token, uint256 amount) external;

function withdrawProtocolFees(address token) external returns (uint256 creationFees, uint256 slashingFees);
function withdrawProtocolFeesByCategory(FeeCategory category, address token) external returns (uint256 amount);
function withdrawTKFees(address token) external;

function getMinFee(address token) external view returns (uint256);
function getProtocolFeePercent(ResolverTrust trust) external view returns (uint256);
function getResolverDefaultFee(address resolver, address token) external view returns (uint256);
function getResolverFee(address resolver, uint32 templateId, address token) external view returns (uint256);
function getProtocolBalance(FeeCategory category, address token) external view returns (uint256);
function getTKBalance(address tk, address token) external view returns (uint256);
function getCreationFee(address resolver, uint32 templateId, address token)
    external view returns (uint256 protocolCut, uint256 resolverShare, uint256 total);
```

**Verification:** Interface compiles

---

## Task 10: Update _slashBondWithReward

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Update to use multi-token balances:**
```solidity
function _slashBondWithReward(
    uint256 tocId,
    address winner,
    address loser,
    address token,
    uint256 amount
) internal {
    uint256 winnerShare = amount / 2;
    uint256 contractShare = amount - winnerShare;

    _transferBondOut(winner, token, winnerShare);

    TOC storage toc = _tocs[tocId];
    uint256 tkShare = (contractShare * tkSharePercent[toc.tierAtCreation]) / 10000;
    uint256 protocolKeeps = contractShare - tkShare;

    // Store in multi-token balances
    protocolBalances[FeeCategory.SLASHING][token] += protocolKeeps;
    if (tkShare > 0) {
        tkBalances[toc.truthKeeper][token] += tkShare;
    }

    emit SlashingFeesCollected(tocId, token, protocolKeeps, tkShare);
    emit BondSlashed(tocId, loser, token, contractShare);
}
```

**Verification:** Function compiles

---

## Task 11: Update Withdrawal Functions

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Replace:**
```solidity
/// @notice Withdraw protocol fees for a specific token
function withdrawProtocolFees(address token) external onlyTreasury nonReentrant
    returns (uint256 creationFees, uint256 slashingFees)
{
    creationFees = protocolBalances[FeeCategory.CREATION][token];
    slashingFees = protocolBalances[FeeCategory.SLASHING][token];

    uint256 total = creationFees + slashingFees;
    if (total == 0) revert NoFeesToWithdraw();

    protocolBalances[FeeCategory.CREATION][token] = 0;
    protocolBalances[FeeCategory.SLASHING][token] = 0;

    _transferOut(token, msg.sender, total);

    emit ProtocolFeesWithdrawn(msg.sender, token, creationFees, slashingFees);
}

/// @notice Withdraw protocol fees by category for a specific token
function withdrawProtocolFeesByCategory(FeeCategory category, address token) external onlyTreasury nonReentrant
    returns (uint256 amount)
{
    amount = protocolBalances[category][token];
    if (amount == 0) revert NoFeesToWithdraw();

    protocolBalances[category][token] = 0;

    _transferOut(token, msg.sender, amount);

    emit ProtocolFeesWithdrawn(
        msg.sender,
        token,
        category == FeeCategory.CREATION ? amount : 0,
        category == FeeCategory.SLASHING ? amount : 0
    );
}

/// @notice Withdraw TK fees for a specific token
function withdrawTKFees(address token) external nonReentrant {
    uint256 amount = tkBalances[msg.sender][token];
    if (amount == 0) revert NoFeesToWithdraw();

    tkBalances[msg.sender][token] = 0;

    _transferOut(token, msg.sender, amount);

    emit TKFeesWithdrawn(msg.sender, token, amount);
}

/// @notice Claim resolver fee for a TOC
function claimResolverFee(uint256 tocId) external nonReentrant {
    TOC storage toc = _tocs[tocId];
    if (msg.sender != toc.resolver) {
        revert NotResolverForToc(msg.sender, tocId);
    }

    uint256 amount = resolverFeeByToc[tocId];
    if (amount == 0) revert NoResolverFee(tocId);

    address token = resolverFeeTokenByToc[tocId];
    resolverFeeByToc[tocId] = 0;

    _transferOut(token, msg.sender, amount);

    emit ResolverFeeClaimed(msg.sender, tocId, token, amount);
}

/// @notice Batch claim resolver fees
function claimResolverFees(uint256[] calldata tocIds) external nonReentrant {
    // Group by token for efficient transfers
    // For simplicity, process one by one (can optimize later)
    for (uint256 i = 0; i < tocIds.length; i++) {
        uint256 tocId = tocIds[i];
        if (tocId == 0 || tocId >= _nextTocId) continue;

        TOC storage toc = _tocs[tocId];
        if (msg.sender != toc.resolver) continue;

        uint256 amount = resolverFeeByToc[tocId];
        if (amount > 0) {
            address token = resolverFeeTokenByToc[tocId];
            resolverFeeByToc[tocId] = 0;
            _transferOut(token, msg.sender, amount);
            emit ResolverFeeClaimed(msg.sender, tocId, token, amount);
        }
    }
}
```

**Add helper:**
```solidity
/// @notice Transfer token out (ETH or ERC20)
function _transferOut(address token, address to, uint256 amount) internal {
    if (token == address(0)) {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    } else {
        IERC20(token).safeTransfer(to, amount);
    }
}
```

**Verification:** Functions compile

---

## Task 12: Update View Functions

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Replace/Add:**
```solidity
function getMinFee(address token) external view returns (uint256) {
    return minFeeByToken[token];
}

function getProtocolFeePercent(ResolverTrust trust) external view returns (uint256) {
    return protocolFeePercent[trust];
}

function getResolverDefaultFee(address resolver, address token) external view returns (uint256) {
    return resolverDefaultFee[resolver][token];
}

function getResolverFee(address resolver, uint32 templateId, address token) external view returns (uint256) {
    return resolverTemplateFees[resolver][templateId][token];
}

function getProtocolBalance(FeeCategory category, address token) external view returns (uint256) {
    return protocolBalances[category][token];
}

function getTKBalance(address tk, address token) external view returns (uint256) {
    return tkBalances[tk][token];
}

function getCreationFee(
    address resolver,
    uint32 templateId,
    address token
) external view returns (uint256 protocolCut, uint256 resolverShare, uint256 total) {
    uint256 minFee = minFeeByToken[token];
    if (minFee == 0) revert TokenNotSupported(token);

    // Get resolver fee (may revert if not supported)
    uint256 resolverFee = _getResolverFee(resolver, templateId, token);

    // Calculate protocol cut
    ResolverTrust trust = _resolverConfigs[resolver].trust;
    uint256 percentageCut = (resolverFee * protocolFeePercent[trust]) / 10000;

    if (trust == ResolverTrust.SYSTEM) {
        protocolCut = percentageCut;
    } else {
        protocolCut = percentageCut > minFee ? percentageCut : minFee;
    }

    resolverShare = resolverFee > protocolCut ? resolverFee - protocolCut : 0;
    total = protocolCut + resolverShare;
}
```

**Remove old functions:**
- `getProtocolFees()`
- `getTKSharePercent()` (keep this one actually - unchanged)
- Old single-token `getProtocolBalance`, `getTKBalance`, `getCreationFee`

**Verification:** Functions compile

---

## Task 13: Update Tests - Setup

**File:** `contracts/test/TOCRegistry.t.sol`

**Update setUp:**
```solidity
function setUp() public {
    // ... existing setup ...

    // Configure multi-token fees
    registry.setMinFee(address(0), 0.001 ether);  // ETH
    registry.setMinFee(address(mockToken), 10e18); // Mock ERC20

    // Set protocol fee percentages
    registry.setProtocolFeePercent(ResolverTrust.RESOLVER, 6000);  // 60%
    registry.setProtocolFeePercent(ResolverTrust.VERIFIED, 4000);  // 40%
    registry.setProtocolFeePercent(ResolverTrust.SYSTEM, 2000);    // 20%

    // Set TK share percentages (unchanged)
    registry.setTKSharePercent(AccountabilityTier.RESOLVER, 0);
    registry.setTKSharePercent(AccountabilityTier.TK_GUARANTEED, 4000);
    registry.setTKSharePercent(AccountabilityTier.SYSTEM, 6000);
}
```

**Update all createTOC calls to include feeToken parameter:**
```solidity
// Before:
registry.createTOC{value: 0.001 ether}(resolver, templateId, payload, ...);

// After:
registry.createTOC{value: 0.001 ether}(resolver, templateId, payload, ..., address(0));
```

**Verification:** Tests compile

---

## Task 14: Update Tests - Fee Tests

**File:** `contracts/test/TOCRegistry.t.sol`

**Add new tests:**
```solidity
function test_MultiTokenFees() public {
    // Setup resolver to accept both ETH and ERC20
    vm.prank(address(resolver));
    registry.setResolverDefaultFee(address(0), 0.002 ether);
    vm.prank(address(resolver));
    registry.setResolverDefaultFee(address(mockToken), 20e18);

    // Create TOC with ETH
    uint256 tocId1 = registry.createTOC{value: 0.002 ether}(..., address(0));

    // Create TOC with ERC20
    mockToken.approve(address(registry), 100e18);
    uint256 tocId2 = registry.createTOC(..., address(mockToken));

    // Verify balances
    assertGt(registry.getProtocolBalance(FeeCategory.CREATION, address(0)), 0);
    assertGt(registry.getProtocolBalance(FeeCategory.CREATION, address(mockToken)), 0);
}

function test_ResolverFeeWithSentinelValues() public {
    // Test MAX = free
    vm.prank(address(resolver));
    registry.setResolverDefaultFee(address(0), type(uint256).max);

    // Should pay only minimum
    (uint256 protocolCut, uint256 resolverShare, uint256 total) =
        registry.getCreationFee(address(resolver), 1, address(0));

    assertEq(resolverShare, 0);
    assertEq(protocolCut, 0.001 ether); // minimum
}

function test_SystemResolverExemptFromMinimum() public {
    registry.setResolverTrust(address(resolver), ResolverTrust.SYSTEM);

    vm.prank(address(resolver));
    registry.setResolverDefaultFee(address(0), 0); // Would normally use MAX for free

    // SYSTEM resolver with 0 fee should result in 0 total
    // ... test implementation
}

function test_RevertTokenNotSupported() public {
    address unsupportedToken = address(0x999);

    vm.expectRevert(abi.encodeWithSelector(
        TOCRegistry.TokenNotSupported.selector,
        unsupportedToken
    ));
    registry.createTOC(..., unsupportedToken);
}

function test_RevertTokenNotSupportedByResolver() public {
    // Resolver hasn't set fee for this token
    vm.expectRevert(abi.encodeWithSelector(
        TOCRegistry.TokenNotSupportedByResolver.selector,
        address(resolver),
        address(mockToken)
    ));
    registry.createTOC(..., address(mockToken));
}
```

**Verification:** All tests pass

---

## Task 15: Update Tests - Withdrawal Tests

**File:** `contracts/test/TOCRegistry.t.sol`

**Update withdrawal tests:**
```solidity
function test_WithdrawProtocolFeesMultiToken() public {
    // Create TOCs in different tokens
    // ...

    // Withdraw ETH fees
    vm.prank(treasury);
    (uint256 creation, uint256 slashing) = registry.withdrawProtocolFees(address(0));
    assertGt(creation, 0);

    // Withdraw ERC20 fees
    vm.prank(treasury);
    (creation, slashing) = registry.withdrawProtocolFees(address(mockToken));
    assertGt(creation, 0);
}

function test_WithdrawTKFeesMultiToken() public {
    // ... test TK withdrawal per token
}
```

**Verification:** All tests pass

---

## Task 16: Final Cleanup and Verification

**Tasks:**
1. Remove any unused old storage/functions
2. Ensure all events are emitted correctly
3. Run full test suite
4. Check contract size
5. Fix any compiler warnings

**Commands:**
```bash
forge build --sizes
forge test
```

**Verification:**
- All tests pass
- Contract size under 24KB
- No compiler warnings (except known ones)

---

## Summary of Breaking Changes

1. `createTOC` has new `feeToken` parameter
2. `protocolFeeMinimum` / `protocolFeeStandard` removed → use `minFeeByToken`
3. `setResolverFee` signature changed (now includes token)
4. All withdrawal functions require token parameter
5. All balance view functions require token parameter
6. Events updated with token parameter

---

## Estimated Task Dependencies

```
Task 1 (Storage) ─┬─► Task 2 (Errors) ─┬─► Task 4 (Admin Config)
                  │                    │
                  │                    └─► Task 5 (Resolver Config)
                  │
                  └─► Task 3 (Events) ─────► Task 7 (_collectCreationFees)
                                              │
Task 6 (Fee Lookup) ──────────────────────────┘
                                              │
Task 8 (createTOC) ◄──────────────────────────┘
       │
       └─► Task 9 (Interface)

Task 10 (_slashBond) ──► Task 11 (Withdrawals) ──► Task 12 (Views)
                                                        │
Task 13 (Test Setup) ──► Task 14 (Fee Tests) ──► Task 15 (Withdrawal Tests)
                                                        │
                                                        ▼
                                                  Task 16 (Cleanup)
```
