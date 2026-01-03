// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "./TOCTypes.sol";

/// @title ITOCResolver
/// @notice Interface that all TOC resolvers must implement
/// @dev Resolvers are responsible for:
///      - Validating TOC creation parameters
///      - Storing template-specific TOC data
///      - Executing resolution logic with their data sources
///      - Generating human-readable questions
interface ITOCResolver {
    /// @notice Check if this resolver manages a given TOC
    /// @param tocId The TOC identifier
    /// @return True if this resolver manages the TOC
    function isTocManaged(uint256 tocId) external view returns (bool);

    /// @notice Called by TruthEngine when a TOC is created
    /// @dev Should revert if payload is invalid for the template
    /// @param tocId The unique TOC identifier assigned by registry
    /// @param templateId The template ID within this resolver
    /// @param payload Encoded creation parameters specific to the template
    /// @param creator The address that created the TOC
    /// @return initialState The initial state (PENDING or ACTIVE)
    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload,
        address creator
    ) external returns (TOCState initialState);

    /// @notice Resolve a TOC with provided proof/data
    /// @dev Called by TruthEngine when someone proposes resolution.
    ///      Result must be ABI-encoded based on template's answerType:
    ///      - BOOLEAN: abi.encode(bool)
    ///      - NUMERIC: abi.encode(int256)
    ///      - GENERIC: raw bytes
    ///      Use TOCResultCodec library for encoding.
    /// @param tocId The TOC identifier
    /// @param caller The address that initiated resolution (for access control)
    /// @param payload Resolver-specific resolution data (e.g., Pyth price proof)
    /// @return result ABI-encoded result based on template's answerType
    function resolveToc(
        uint256 tocId,
        address caller,
        bytes calldata payload
    ) external returns (bytes memory result);

    /// @notice Get TOC details stored by this resolver
    /// @param tocId The TOC identifier
    /// @return templateId The template used for this TOC
    /// @return creationPayload The original creation payload
    function getTocDetails(uint256 tocId)
        external
        view
        returns (uint32 templateId, bytes memory creationPayload);

    /// @notice Generate human-readable question for this TOC
    /// @dev e.g., "Will BTC be above $100,000 at Jan 1, 2026?"
    /// @param tocId The TOC identifier
    /// @return question The formatted question string
    function getTocQuestion(uint256 tocId)
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
