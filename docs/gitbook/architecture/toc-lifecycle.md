# TOC Lifecycle

## State Machine

```
                    ┌──────────┐
                    │   NONE   │
                    └────┬─────┘
                         │ createTOC()
                         ▼
                    ┌──────────┐
          ┌─────────│ PENDING  │─────────┐
          │         └────┬─────┘         │
          │ reject()     │ activate()    │
          ▼              ▼               │
    ┌──────────┐   ┌──────────┐          │
    │ REJECTED │   │  ACTIVE  │          │
    └──────────┘   └────┬─────┘          │
                        │ resolveTOC()   │
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
function createTOC(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    address truthKeeper,
    uint32 disputeWindow,
    uint32 truthKeeperWindow,
    uint32 escalationWindow,
    uint32 postResolutionWindow
) external returns (uint256 tocId);
```

- Resolver validates payload via `onTocCreated()`
- Resolver returns initial state (PENDING or ACTIVE)
- Accountability tier calculated and frozen
- Time windows stored for later use

### 2. Resolution

```solidity
function resolveTOC(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount,
    bytes calldata payload
) external;
```

- Proposer stakes resolution bond
- Resolver executes `resolveToc()` and returns ABI-encoded result
- Dispute window opens
- State → RESOLVING

### 3. Dispute (Optional)

```solidity
function disputeTOC(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount
) external;
```

- Disputer stakes higher bond than proposer
- State → DISPUTED_ROUND_1
- TruthKeeper has `truthKeeperWindow` to decide

### 4. Finalization

```solidity
function finalizeTOC(uint256 tocId) external;
```

- Called after dispute window expires (if no dispute)
- Or after dispute resolution completes
- State → RESOLVED
