# Multi-Token Fee System Design

## Overview

This document describes the multi-token fee system for TOC Core, extending the initial ETH-only implementation to support multiple tokens (ETH, USDC, project tokens, etc.).

---

## Key Design Decisions

1. **Global token whitelist** - Admin-managed list of accepted tokens
2. **Single token per transaction** - User pays all fees in one chosen token
3. **Fixed amounts per token** - No oracles, admin sets minimum fees per token
4. **Protocol takes % or minimum** - Higher of (% of resolver fee) or (min fee)
5. **SYSTEM resolvers exempt from minimum** - Trusted partners can operate below min
6. **Resolver trust affects protocol cut** - Higher trust = lower % to protocol
7. **TK share from protocol's cut** - Same as current, tier-based percentages
8. **Sentinel values for resolver fees** - 0 = unset, MAX = free, other = amount
9. **Per-token withdrawals** - Caller specifies which token to withdraw
10. **Preserve fee categories** - CREATION/SLASHING distinction maintained

---

## Token Whitelist

The whitelist is implicit in the `minFeeByToken` mapping:

```solidity
mapping(address => uint256) public minFeeByToken;
```

- `minFeeByToken[token] > 0` means token is supported
- `minFeeByToken[token] == 0` means token is not supported

**Admin Functions:**
```solidity
function setMinFee(address token, uint256 amount) external onlyOwner;
```
- Setting `amount > 0` adds token to whitelist
- Setting `amount = 0` removes token from whitelist

---

## Protocol Fee Percentage by Resolver Trust

```solidity
mapping(ResolverTrust => uint256) public protocolFeePercent; // basis points
```

| ResolverTrust | Protocol Takes | Resolver Keeps |
|---------------|----------------|----------------|
| RESOLVER      | 60% (6000 bp)  | 40%            |
| VERIFIED      | 40% (4000 bp)  | 60%            |
| SYSTEM        | 20% (2000 bp)  | 80%            |

**Special Rule:** SYSTEM resolvers are exempt from minimum fee requirement.

---

## Resolver Fee Configuration

### Storage

```solidity
// Resolver's default fee per token (applies to all templates unless overridden)
mapping(address => mapping(address => uint256)) public resolverDefaultFee;
// resolver => token => fee

// Resolver's fee per template per token (overrides default)
mapping(address => mapping(uint32 => mapping(address => uint256))) public resolverTemplateFees;
// resolver => templateId => token => fee
```

### Sentinel Values

- `0` = unset (fall through to default, or revert if no default)
- `type(uint256).max` = explicitly free (0 fee)
- Any other value = actual fee amount

### Lookup Order

```
1. Check resolverTemplateFees[resolver][templateId][token]
   - If > 0 and < MAX → use this fee
   - If == MAX → fee is 0
   - If == 0 → continue to step 2

2. Check resolverDefaultFee[resolver][token]
   - If > 0 and < MAX → use this fee
   - If == MAX → fee is 0
   - If == 0 → revert TokenNotSupportedByResolver(resolver, token)
```

### Configuration Functions

```solidity
// Set default fee for a token (resolver calls this)
function setResolverDefaultFee(address token, uint256 amount) external;

// Set fee for specific template + token (resolver calls this)
function setResolverFee(uint32 templateId, address token, uint256 amount) external;
```

---

## Fee Calculation Flow

When `createTOC()` is called with payment in token T:

### Step 1: Validate Token
```solidity
if (minFeeByToken[T] == 0) revert TokenNotSupported(T);
```

### Step 2: Lookup Resolver Fee
```solidity
uint256 resolverFee = _getResolverFee(resolver, templateId, T);
// Uses lookup order above, may revert if resolver doesn't support token
// MAX value is converted to 0
```

### Step 3: Calculate Protocol Cut
```solidity
uint256 percentageCut = (resolverFee * protocolFeePercent[resolverTrust]) / 10000;

uint256 protocolCut;
if (resolverTrust == ResolverTrust.SYSTEM) {
    // SYSTEM resolvers exempt from minimum
    protocolCut = percentageCut;
} else {
    // Others pay at least minimum
    protocolCut = max(minFeeByToken[T], percentageCut);
}
```

### Step 4: Calculate Splits
```solidity
uint256 resolverShare = resolverFee > protocolCut ? resolverFee - protocolCut : 0;
uint256 tkShare = (protocolCut * tkSharePercent[accountabilityTier]) / 10000;
uint256 protocolKeeps = protocolCut - tkShare;
```

### Step 5: Collect Payment
```solidity
uint256 totalFee = protocolCut + resolverShare; // equals resolverFee, or protocolCut if resolver charges less than min
_transferIn(T, totalFee);
```

### Step 6: Store Balances
```solidity
protocolBalances[FeeCategory.CREATION][T] += protocolKeeps;
if (tkShare > 0) tkBalances[tk][T] += tkShare;
if (resolverShare > 0) {
    resolverFeeByToc[tocId] = resolverShare;
    resolverFeeTokenByToc[tocId] = T;
}
```

---

## Fee Examples

### Example 1: VERIFIED Resolver, Standard Fee

- Token: USDC, minFee = 2 USDC
- Resolver charges: 10 USDC
- ResolverTrust: VERIFIED (40% to protocol)
- AccountabilityTier: TK_GUARANTEED (40% to TK)

```
Protocol cut = max(2, 10 * 40%) = max(2, 4) = 4 USDC
Resolver gets = 10 - 4 = 6 USDC
TK gets = 4 * 40% = 1.6 USDC
Protocol keeps = 4 - 1.6 = 2.4 USDC
```

### Example 2: RESOLVER Trust, Low Fee

- Token: ETH, minFee = 0.0005 ETH
- Resolver charges: 0.0006 ETH
- ResolverTrust: RESOLVER (60% to protocol)
- AccountabilityTier: RESOLVER (0% to TK)

```
Protocol cut = max(0.0005, 0.0006 * 60%) = max(0.0005, 0.00036) = 0.0005 ETH
Resolver gets = 0.0006 - 0.0005 = 0.0001 ETH
TK gets = 0 (RESOLVER tier)
Protocol keeps = 0.0005 ETH
```

### Example 3: SYSTEM Resolver, Free

- Token: PROJECT_TOKEN, minFee = 100 tokens
- Resolver charges: 0 (MAX sentinel)
- ResolverTrust: SYSTEM (20% to protocol, exempt from min)
- AccountabilityTier: SYSTEM (60% to TK)

```
Protocol cut = 0 * 20% = 0 (SYSTEM exempt from min)
Resolver gets = 0
TK gets = 0
Protocol keeps = 0
Total user pays = 0
```

### Example 4: VERIFIED Resolver, Free Template

- Token: USDC, minFee = 2 USDC
- Resolver charges: 0 (MAX sentinel)
- ResolverTrust: VERIFIED (40% to protocol)
- AccountabilityTier: TK_GUARANTEED (40% to TK)

```
Protocol cut = max(2, 0 * 40%) = 2 USDC (minimum applies)
Resolver gets = 0
TK gets = 2 * 40% = 0.8 USDC
Protocol keeps = 2 - 0.8 = 1.2 USDC
Total user pays = 2 USDC
```

---

## Storage Summary

### New/Modified State Variables

```solidity
// Token minimum fees (also serves as whitelist)
mapping(address => uint256) public minFeeByToken;

// Protocol fee percentage by resolver trust (basis points)
mapping(ResolverTrust => uint256) public protocolFeePercent;

// Resolver default fees per token
mapping(address => mapping(address => uint256)) public resolverDefaultFee;

// Resolver template fees per token (replaces old single-token version)
mapping(address => mapping(uint32 => mapping(address => uint256))) public resolverTemplateFees;

// Protocol balances by category by token (replaces old single-token version)
mapping(FeeCategory => mapping(address => uint256)) public protocolBalances;

// TK balances by token (replaces old single-token version)
mapping(address => mapping(address => uint256)) public tkBalances;

// Resolver fee info per TOC
mapping(uint256 => uint256) public resolverFeeByToc;      // amount
mapping(uint256 => address) public resolverFeeTokenByToc; // token
```

### Removed State Variables

```solidity
// These are replaced by new mappings above
uint256 public protocolFeeMinimum;   // → minFeeByToken
uint256 public protocolFeeStandard;  // → minFeeByToken + protocolFeePercent
```

---

## Function Changes

### Admin Functions

```solidity
// Token whitelist management
function setMinFee(address token, uint256 amount) external onlyOwner;

// Protocol fee percentage by trust level
function setProtocolFeePercent(ResolverTrust trust, uint256 basisPoints) external onlyOwner;
```

### Resolver Functions

```solidity
// Set default fee for a token
function setResolverDefaultFee(address token, uint256 amount) external nonReentrant;

// Set fee for specific template + token
function setResolverFee(uint32 templateId, address token, uint256 amount) external nonReentrant;
```

### Withdrawal Functions

```solidity
// Protocol withdrawals (per token)
function withdrawProtocolFees(address token) external onlyTreasury nonReentrant
    returns (uint256 creationFees, uint256 slashingFees);

function withdrawProtocolFeesByCategory(FeeCategory category, address token) external onlyTreasury nonReentrant
    returns (uint256 amount);

// TK withdrawal (per token)
function withdrawTKFees(address token) external nonReentrant;

// Resolver withdrawal (uses stored token)
function claimResolverFee(uint256 tocId) external nonReentrant;
function claimResolverFees(uint256[] calldata tocIds) external nonReentrant;
```

### View Functions

```solidity
function getMinFee(address token) external view returns (uint256);
function getProtocolFeePercent(ResolverTrust trust) external view returns (uint256);
function getResolverDefaultFee(address resolver, address token) external view returns (uint256);
function getResolverFee(address resolver, uint32 templateId, address token) external view returns (uint256);
function getProtocolBalance(FeeCategory category, address token) external view returns (uint256);
function getTKBalance(address tk, address token) external view returns (uint256);

// Updated to include token
function getCreationFee(address resolver, uint32 templateId, address token)
    external view returns (uint256 protocolCut, uint256 resolverShare, uint256 total);
```

---

## Events

```solidity
// Configuration events
event MinFeeSet(address indexed token, uint256 amount);
event ProtocolFeePercentSet(ResolverTrust indexed trust, uint256 basisPoints);
event ResolverDefaultFeeSet(address indexed resolver, address indexed token, uint256 amount);
event ResolverFeeSet(address indexed resolver, uint32 indexed templateId, address indexed token, uint256 amount);

// Fee collection events (updated with token)
event CreationFeesCollected(
    uint256 indexed tocId,
    address indexed token,
    uint256 protocolFee,
    uint256 tkFee,
    uint256 resolverFee
);
event SlashingFeesCollected(
    uint256 indexed tocId,
    address indexed token,
    uint256 protocolFee,
    uint256 tkFee
);

// Withdrawal events (updated with token)
event ProtocolFeesWithdrawn(address indexed treasury, address indexed token, uint256 creationFees, uint256 slashingFees);
event TKFeesWithdrawn(address indexed tk, address indexed token, uint256 amount);
event ResolverFeeClaimed(address indexed resolver, uint256 indexed tocId, address indexed token, uint256 amount);
```

---

## Error Definitions

```solidity
error TokenNotSupported(address token);
error TokenNotSupportedByResolver(address resolver, address token);
error InvalidFeePercent(uint256 basisPoints);
```

---

## Slashing Integration

When bonds are slashed, the protocol's share is split with TK based on tier. With multi-token:

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

    protocolBalances[FeeCategory.SLASHING][token] += protocolKeeps;
    if (tkShare > 0) {
        tkBalances[toc.truthKeeper][token] += tkShare;
    }

    emit SlashingFeesCollected(tocId, token, protocolKeeps, tkShare);
    emit BondSlashed(tocId, loser, token, contractShare);
}
```

---

## Migration Considerations

1. **Existing storage**: Current ETH balances need migration path
2. **Existing TOCs**: Continue to work with ETH
3. **Default values**: Set initial `minFeeByToken[ETH]` and `protocolFeePercent` values

---

## Future Considerations (Out of Scope)

1. **Oracle-based pricing** - Convert fees to USD equivalent at runtime
2. **DEX integration** - Auto-swap received tokens to canonical token
3. **Batch withdrawals** - Withdraw multiple tokens in one transaction
4. **Token-specific TK shares** - Different TK percentages per token
