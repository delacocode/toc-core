# Type Reference

## Enums

### TOCState

```solidity
enum TOCState {
    NONE,
    PENDING,
    REJECTED,
    ACTIVE,
    RESOLVING,
    DISPUTED_ROUND_1,
    DISPUTED_ROUND_2,
    RESOLVED,
    CANCELLED
}
```

### AnswerType

```solidity
enum AnswerType {
    NONE,
    BOOLEAN,
    NUMERIC,
    GENERIC
}
```

### ResolverTrust

```solidity
enum ResolverTrust {
    NONE,
    PERMISSIONLESS,
    VERIFIED,
    SYSTEM
}
```

### AccountabilityTier

```solidity
enum AccountabilityTier {
    NONE,
    PERMISSIONLESS,
    TK_GUARANTEED,
    SYSTEM
}
```

### DisputeResolution

```solidity
enum DisputeResolution {
    UPHOLD_DISPUTE,
    REJECT_DISPUTE,
    CANCEL_TOC,
    TOO_EARLY
}
```

## Structs

### TOC

```solidity
struct TOC {
    address resolver;
    address creator;
    address truthKeeper;
    uint32 templateId;
    AnswerType answerType;
    TOCState state;
    AccountabilityTier tier;
    uint32 disputeWindow;
    uint32 truthKeeperWindow;
    uint32 escalationWindow;
    uint32 postResolutionWindow;
    uint64 createdAt;
    uint64 resolvedAt;
}
```

### ExtensiveResult

```solidity
struct ExtensiveResult {
    bytes result;
    bool finalized;
    bool disputed;
    bool hasCorrectedResult;
    AccountabilityTier tier;
    ResolverTrust resolverTrust;
}
```
