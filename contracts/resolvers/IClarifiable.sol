// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/// @notice Response when a clarification is requested
enum ClarificationResponse {
    ACCEPT,    // Clarification added immediately
    REJECT,    // Clarification refused
    PENDING    // Needs resolver approval
}

/// @title IClarifiable
/// @notice Interface for resolvers that support question clarifications
/// @dev Resolvers implement this to allow TOC creators to add clarifications to their questions
interface IClarifiable {
    // ============ Events ============

    /// @notice Emitted when a clarification is requested
    /// @param tocId The TOC identifier
    /// @param creator The TOC creator who requested the clarification
    /// @param clarificationId The ID of this clarification (per-TOC, starts at 0)
    /// @param text The clarification text
    event ClarificationRequested(
        uint256 indexed tocId,
        address indexed creator,
        uint256 clarificationId,
        string text
    );

    /// @notice Emitted when a pending clarification is accepted
    /// @param tocId The TOC identifier
    /// @param clarificationId The clarification ID that was accepted
    event ClarificationAccepted(uint256 indexed tocId, uint256 clarificationId);

    /// @notice Emitted when a clarification is rejected
    /// @param tocId The TOC identifier
    /// @param clarificationId The clarification ID that was rejected
    event ClarificationRejected(uint256 indexed tocId, uint256 clarificationId);

    // ============ Write Functions ============

    /// @notice Request to add a clarification to a TOC
    /// @dev Only the TOC creator can call this. Resolver decides to accept, reject, or pend.
    /// @param tocId The TOC identifier
    /// @param text The clarification text
    /// @return response The resolver's response (ACCEPT, REJECT, or PENDING)
    /// @return clarificationId The ID assigned to this clarification
    function requestClarification(
        uint256 tocId,
        string calldata text
    ) external returns (ClarificationResponse response, uint256 clarificationId);

    /// @notice Approve a pending clarification
    /// @dev Only resolver admin can call this
    /// @param tocId The TOC identifier
    /// @param clarificationId The clarification ID to approve
    function approveClarification(uint256 tocId, uint256 clarificationId) external;

    /// @notice Reject a pending clarification
    /// @dev Only resolver admin can call this
    /// @param tocId The TOC identifier
    /// @param clarificationId The clarification ID to reject
    function rejectClarification(uint256 tocId, uint256 clarificationId) external;

    // ============ View Functions ============

    /// @notice Get all accepted clarifications for a TOC
    /// @param tocId The TOC identifier
    /// @return clarifications Array of accepted clarification strings
    function getClarifications(uint256 tocId) external view returns (string[] memory clarifications);

    /// @notice Get all pending clarifications for a TOC
    /// @param tocId The TOC identifier
    /// @return ids Array of pending clarification IDs
    /// @return texts Array of pending clarification texts
    function getPendingClarifications(
        uint256 tocId
    ) external view returns (uint256[] memory ids, string[] memory texts);
}
