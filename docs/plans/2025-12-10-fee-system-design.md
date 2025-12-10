# Fee System Design

## Overview

This document describes the fee system for TOC Core, covering revenue collection, distribution, and withdrawal mechanisms.

### Revenue Streams

The protocol collects fees from two sources:

1. **Creation Fees** - Paid when `createPOP()` is called
   - Protocol fee (minimum or standard based on TK presence)
   - Resolver fee (per-template, set by resolver)
   - TK share (percentage of protocol fee, tier-based)

2. **Slashing Fees** - Collected when disputes resolve
   - 50% to winner, 50% to protocol (existing behavior)
   - TK gets tier-based share of protocol's portion

### Fee Token

ETH only for initial implementation. Multi-token support can be added later.

### Naming Change

- `AccountabilityTier.PERMISSIONLESS` → `AccountabilityTier.RESOLVER`
- `ResolverTrust.PERMISSIONLESS` → `ResolverTrust.RESOLVER`

---

## Protocol Fee Structure

### Fee Levels

| Condition | Protocol Fee | Description |
|-----------|--------------|-------------|
| No TK (`address(0)`) | Minimum (configurable) | No TK involvement, lowest tier |
| TK assigned | Standard (configurable) | Same for TK_GUARANTEED and SYSTEM |

**Defaults:**
- Minimum: 0.0005 ETH
- Standard: 0.001 ETH

### TK Share (from Protocol Fee)

| Tier | TK Gets | Protocol Keeps |
|------|---------|----------------|
| RESOLVER | 0% | 100% |
| TK_GUARANTEED | 40% | 60% |
| SYSTEM | 60% | 40% |

Percentages are configurable by admin (stored in basis points).

---

## Resolver Fee Structure

- Stored per resolver + template: `resolverTemplateFees[resolver][templateId]`
- Resolver sets via `setResolverFee(templateId, amount)`
- Default: 0 (resolver can choose not to charge)
- Stored per-POP after creation: `resolverFeeByPop[popId]`

This per-POP tracking allows resolvers to implement custom distribution logic (e.g., share with data providers, oracles).

---

## Creation Fee Flow

When `createPOP()` is called:

```
Total Payment = Protocol Fee + Resolver Fee
```

### Example (TK_GUARANTEED tier, resolver charges 0.002 ETH):

```
User pays:          0.003 ETH total
├── Protocol fee:   0.001 ETH (standard)
│   ├── TK share:   0.0004 ETH (40%)
│   └── Protocol:   0.0006 ETH (60%)
└── Resolver fee:   0.002 ETH (stored per-POP)
```

### Storage After createPOP:

- Protocol portion → `protocolBalances[CREATION]`
- TK portion → `tkBalances[tkAddress]`
- Resolver portion → `resolverFeeByPop[popId]`

---

## Slashing Fee Distribution

Existing 50/50 split unchanged. New: TK gets share of protocol's portion.

### Example (0.1 ETH bond slashed, TK_GUARANTEED tier):

```
Bond slashed:       0.1 ETH
├── Winner gets:    0.05 ETH (50%)
└── Protocol portion: 0.05 ETH (50%)
    ├── TK share:   0.02 ETH (40%)
    └── Protocol:   0.03 ETH (60%)
```

### Storage:

- Protocol portion → `protocolBalances[SLASHING]`
- TK portion → `tkBalances[tkAddress]`

### Applies To:

- Resolution bond slashing (dispute upheld)
- Dispute bond slashing (dispute rejected)
- Escalation bond slashing (escalation rejected)

---

## Withdrawal Functions

### Protocol Withdrawal

```solidity
function withdrawProtocolFees() external returns (uint256 creationFees, uint256 slashingFees)
```
- Callable by treasury address only
- Sends all accumulated fees to treasury (msg.sender)
- Returns amounts per category for treasury to handle appropriately

```solidity
function withdrawProtocolFeesByCategory(FeeCategory category) external returns (uint256 amount)
```
- Callable by treasury address only
- Withdraw specific category only

```solidity
function setTreasury(address treasury) external onlyOwner
```
- Admin sets treasury address

### TK Withdrawal

```solidity
function withdrawTKFees() external
```
- Caller receives their accumulated TK fees
- `tkBalances[msg.sender]` → sent to msg.sender, balance zeroed

### Resolver Withdrawal

```solidity
function claimResolverFee(uint256 popId) external
```
- Only resolver of that POP can call
- Sends `resolverFeeByPop[popId]` to resolver address

```solidity
function claimResolverFees(uint256[] calldata popIds) external
```
- Batch claim for multiple POPs
- Gas efficient for active resolvers

---

## Configuration Functions

### Protocol Configuration (admin only)

```solidity
function setTreasury(address treasury) external onlyOwner
function setProtocolFeeMinimum(uint256 amount) external onlyOwner
function setProtocolFeeStandard(uint256 amount) external onlyOwner
function setTKSharePercent(AccountabilityTier tier, uint256 basisPoints) external onlyOwner
```

### Resolver Configuration

```solidity
function setResolverFee(uint32 templateId, uint256 amount) external
```
- Caller must be a registered resolver
- Sets fee for that resolver + template combination

---

## View Functions

```solidity
function getCreationFee(address resolver, uint32 templateId, address truthKeeper)
    external view returns (uint256 protocolFee, uint256 resolverFee, uint256 total)
```
- Returns total cost to create a POP with given parameters

```solidity
function getProtocolFeeMinimum() external view returns (uint256)
function getProtocolFeeStandard() external view returns (uint256)
function getTKSharePercent(AccountabilityTier tier) external view returns (uint256)
function getResolverFee(address resolver, uint32 templateId) external view returns (uint256)
function getProtocolBalance(FeeCategory category) external view returns (uint256)
function getTKBalance(address tk) external view returns (uint256)
function getResolverFeeByPop(uint256 popId) external view returns (uint256)
```

---

## Storage

### New State Variables

```solidity
// Protocol configuration
address public treasury;
uint256 public protocolFeeMinimum;      // Fee when TK == address(0)
uint256 public protocolFeeStandard;     // Fee when TK assigned

// TK share percentages (basis points, e.g., 4000 = 40%)
mapping(AccountabilityTier => uint256) public tkSharePercent;

// Protocol balances by category
enum FeeCategory { CREATION, SLASHING }
mapping(FeeCategory => uint256) public protocolBalances;

// TK balances (aggregate per TK)
mapping(address => uint256) public tkBalances;

// Resolver fees (per POP)
mapping(uint256 => uint256) public resolverFeeByPop;

// Resolver fee configuration (per resolver, per template)
mapping(address => mapping(uint32 => uint256)) public resolverTemplateFees;
```

---

## Events

```solidity
// Configuration events
event TreasurySet(address indexed treasury);
event ProtocolFeeUpdated(uint256 minimum, uint256 standard);
event TKShareUpdated(AccountabilityTier indexed tier, uint256 basisPoints);
event ResolverFeeSet(address indexed resolver, uint32 indexed templateId, uint256 amount);

// Fee collection events
event CreationFeesCollected(uint256 indexed popId, uint256 protocolFee, uint256 tkFee, uint256 resolverFee);
event SlashingFeesCollected(uint256 indexed popId, uint256 protocolFee, uint256 tkFee);

// Withdrawal events
event ProtocolFeesWithdrawn(address indexed treasury, uint256 creationFees, uint256 slashingFees);
event TKFeesWithdrawn(address indexed tk, uint256 amount);
event ResolverFeeClaimed(address indexed resolver, uint256 indexed popId, uint256 amount);
```

---

## Future Enhancements (Out of Scope)

1. **Multi-token support** - Allow fees in USDC, DAI, protocol token
2. **Bounty system** - Separate `BountyManager.sol` contract for POP incentivization
3. **Per-template resolver fees** - Already designed, can be extended
4. **Configurable slashing ratios** - Currently fixed at 50/50

---

## Implementation Notes

1. **createPOP changes:**
   - Must be `payable`
   - Calculate and validate fee payment
   - Distribute to protocol, TK, and resolver balances
   - Revert if insufficient payment

2. **Fee calculation at createPOP:**
   ```solidity
   uint256 protocolFee = (truthKeeper == address(0))
       ? protocolFeeMinimum
       : protocolFeeStandard;
   uint256 resolverFee = resolverTemplateFees[resolver][templateId];
   require(msg.value >= protocolFee + resolverFee, "Insufficient fee");
   ```

3. **TK share calculation:**
   ```solidity
   uint256 tkShare = (protocolFee * tkSharePercent[tier]) / 10000;
   uint256 protocolKeeps = protocolFee - tkShare;
   ```

4. **Slashing modification:**
   - Update `_slashBondWithReward` to split protocol portion with TK
   - Add TK address parameter or lookup from POP

5. **Refund excess:**
   - If user overpays, refund the difference
