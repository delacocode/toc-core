// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "./POPTypes.sol";

/// @title IPopResolver
/// @notice Interface that all POP resolvers must implement
/// @dev Resolvers are responsible for:
///      - Validating POP creation parameters
///      - Storing template-specific POP data
///      - Executing resolution logic with their data sources
///      - Generating human-readable questions
interface IPopResolver {
    /// @notice Check if this resolver manages a given POP
    /// @param popId The POP identifier
    /// @return True if this resolver manages the POP
    function isPopManaged(uint256 popId) external view returns (bool);

    /// @notice Called by POPRegistry when a POP is created
    /// @dev Should revert if payload is invalid for the template
    /// @param popId The unique POP identifier assigned by registry
    /// @param templateId The template ID within this resolver
    /// @param payload Encoded creation parameters specific to the template
    /// @return initialState The initial state (PENDING or ACTIVE)
    function onPopCreated(
        uint256 popId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (POPState initialState);

    /// @notice Resolve a POP with provided proof/data
    /// @dev Called by POPRegistry when someone proposes resolution.
    ///      Result must be ABI-encoded based on template's answerType:
    ///      - BOOLEAN: abi.encode(bool)
    ///      - NUMERIC: abi.encode(int256)
    ///      - GENERIC: raw bytes
    ///      Use POPResultCodec library for encoding.
    /// @param popId The POP identifier
    /// @param caller The address that initiated resolution (for access control)
    /// @param payload Resolver-specific resolution data (e.g., Pyth price proof)
    /// @return result ABI-encoded result based on template's answerType
    function resolvePop(
        uint256 popId,
        address caller,
        bytes calldata payload
    ) external returns (bytes memory result);

    /// @notice Get POP details stored by this resolver
    /// @param popId The POP identifier
    /// @return templateId The template used for this POP
    /// @return creationPayload The original creation payload
    function getPopDetails(uint256 popId)
        external
        view
        returns (uint32 templateId, bytes memory creationPayload);

    /// @notice Generate human-readable question for this POP
    /// @dev e.g., "Will BTC be above $100,000 at Jan 1, 2026?"
    /// @param popId The POP identifier
    /// @return question The formatted question string
    function getPopQuestion(uint256 popId)
        external
        view
        returns (string memory question);

    /// @notice Get the number of templates this resolver supports
    /// @return count Number of templates
    function getTemplateCount() external view returns (uint32 count);

    /// @notice Check if a template ID is valid for this resolver
    /// @param templateId The template ID to check
    /// @return True if template exists
    function isValidTemplate(uint32 templateId) external view returns (bool);

    /// @notice Get the answer type for a template
    /// @param templateId The template ID to check
    /// @return answerType The type of answer this template produces
    function getTemplateAnswerType(uint32 templateId) external view returns (AnswerType answerType);
}
