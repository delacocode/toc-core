# POP Lifecycle

## State Machine

```
                    ┌──────────┐
                    │   NONE   │
                    └────┬─────┘
                         │ createPOP()
                         ▼
                    ┌──────────┐
          ┌─────────│ PENDING  │─────────┐
          │         └────┬─────┘         │
          │ reject()     │ activate()    │
          ▼              ▼               │
    ┌──────────┐   ┌──────────┐          │
    │ REJECTED │   │  ACTIVE  │          │
    └──────────┘   └────┬─────┘          │
                        │ resolvePOP()   │
                        ▼                │
                   ┌───────────┐         │
                   │ RESOLVING │         │
                   └─────┬─────┘         │
            ┌────────────┼────────────┐  │
            │ no dispute │ dispute()  │  │
            ▼            ▼            │  │
      ┌──────────┐ ┌─────────────────┐│  │
      │ RESOLVED │ │ DISPUTED_ROUND_1││  │
      └────┬─────┘ └────────┬────────┘│  │
           │                │         │  │
           │     ┌──────────┴─────┐   │  │
           │     │ TK decides OR  │   │  │
           │     │ escalation     │   │  │
           │     ▼                │   │  │
           │ ┌─────────────────┐  │   │  │
           │ │ DISPUTED_ROUND_2│  │   │  │
           │ └────────┬────────┘  │   │  │
           │          │ admin     │   │  │
           │          │ resolves  │   │  │
           │          ▼           │   │  │
           │    ┌──────────┐      │   │  │
           └───►│ RESOLVED │◄─────┘   │  │
                └────┬─────┘          │  │
                     │                │  │
                     ▼                │  │
                ┌──────────┐          │  │
                │CANCELLED │◄─────────┴──┘
                └──────────┘
```

## Lifecycle Phases

### 1. Creation

```solidity
function createPOP(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    address truthKeeper,
    uint32 disputeWindow,
    uint32 truthKeeperWindow,
    uint32 escalationWindow,
    uint32 postResolutionWindow
) external returns (uint256 popId);
```

- Resolver validates payload via `onPopCreated()`
- Resolver returns initial state (PENDING or ACTIVE)
- Accountability tier calculated and frozen
- Time windows stored for later use

### 2. Resolution

```solidity
function resolvePOP(
    uint256 popId,
    address bondToken,
    uint256 bondAmount,
    bytes calldata payload
) external;
```

- Proposer stakes resolution bond
- Resolver executes `resolvePop()` and returns ABI-encoded result
- Dispute window opens
- State → RESOLVING

### 3. Dispute (Optional)

```solidity
function disputePOP(
    uint256 popId,
    address bondToken,
    uint256 bondAmount
) external;
```

- Disputer stakes higher bond than proposer
- State → DISPUTED_ROUND_1
- TruthKeeper has `truthKeeperWindow` to decide

### 4. Finalization

```solidity
function finalizePOP(uint256 popId) external;
```

- Called after dispute window expires (if no dispute)
- Or after dispute resolution completes
- State → RESOLVED
