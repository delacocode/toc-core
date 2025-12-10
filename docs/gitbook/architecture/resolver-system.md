# Resolver System

## Interface

Every resolver must implement:

```solidity
interface ITOCResolver {
    // Called when TOC is created - validate and store question data
    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (TOCState initialState);

    // Called to resolve - return ABI-encoded result
    function resolveToc(
        uint256 tocId,
        address caller,
        bytes calldata payload
    ) external returns (bytes memory result);

    // Human-readable question for UI/display
    function getTocQuestion(uint256 tocId)
        external view returns (string memory);

    // Template metadata
    function getTemplateCount() external view returns (uint32);
    function isValidTemplate(uint32 templateId) external view returns (bool);
    function getTemplateAnswerType(uint32 templateId)
        external view returns (AnswerType);
}
```

## Answer Types

```solidity
enum AnswerType {
    NONE,      // Invalid/unset
    BOOLEAN,   // Yes/No - encoded as abi.encode(bool)
    NUMERIC,   // Integer - encoded as abi.encode(int256)
    GENERIC    // Arbitrary - raw bytes
}
```

## Resolver Trust Levels

```solidity
enum ResolverTrust {
    NONE,           // Not registered
    PERMISSIONLESS, // Registered, no vetting
    VERIFIED,       // Admin-reviewed
    SYSTEM          // Official ecosystem resolver
}
```

## Example: PythPriceResolver

Templates:
- **Template 0 (Snapshot)**: Is price above/below threshold at deadline?
- **Template 1 (Range)**: Is price within [min, max] at deadline?
- **Template 2 (Reached By)**: Did price reach target before deadline?

All return BOOLEAN results via `TOCResultCodec.encodeBoolean()`.

## Example: OptimisticResolver

Templates:
- **Template 0 (Arbitrary)**: Free-form yes/no with description
- **Template 1 (Sports)**: Structured games (winner, spread, over-under)
- **Template 2 (Event)**: Did specific event occur?

Supports clarifications and question updates before resolution.
