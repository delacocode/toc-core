// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "contracts/TOCRegistry/TOCRegistry.sol";
import "contracts/TOCRegistry/TOCTypes.sol";
import "contracts/libraries/TOCResultCodec.sol";

/// @title TestHelpers
/// @notice Reusable test helpers that combine action execution with full effect verification
/// @dev Each helper captures state before, expects events, executes action, and asserts all state changes
abstract contract TestHelpers is Test {
    // ============ Events (must match ITOCRegistry) ============

    event TOCCreated(
        uint256 indexed tocId,
        address indexed resolver,
        ResolverTrust trust,
        uint32 templateId,
        AnswerType answerType,
        TOCState initialState,
        address indexed truthKeeper,
        AccountabilityTier tier
    );

    event CreationFeesCollected(
        uint256 indexed tocId,
        uint256 protocolFee,
        uint256 tkFee,
        uint256 resolverFee
    );

    event TOCResolutionProposed(
        uint256 indexed tocId,
        address indexed proposer,
        AnswerType answerType,
        uint256 disputeDeadline
    );

    event ResolutionBondDeposited(
        uint256 indexed tocId,
        address indexed proposer,
        address token,
        uint256 amount
    );

    event TOCDisputed(
        uint256 indexed tocId,
        address indexed disputer,
        string reason
    );

    event PostResolutionDisputeFiled(
        uint256 indexed tocId,
        address indexed disputer,
        string reason
    );

    event DisputeBondDeposited(
        uint256 indexed tocId,
        address indexed disputer,
        address token,
        uint256 amount
    );

    event TOCFinalized(uint256 indexed tocId, AnswerType answerType);

    event ResolutionBondReturned(
        uint256 indexed tocId,
        address indexed to,
        address token,
        uint256 amount
    );

    event DisputeResolved(
        uint256 indexed tocId,
        DisputeResolution resolution,
        address indexed admin
    );

    event PostResolutionDisputeResolved(
        uint256 indexed tocId,
        bool resultCorrected
    );

    // ============ Structs for Expected State ============

    struct CreateTOCParams {
        address resolver;
        uint32 templateId;
        bytes payload;
        uint32 disputeWindow;
        uint32 tkWindow;
        uint32 escalationWindow;
        uint32 postResolutionWindow;
        address truthKeeper;
        uint256 fee;
    }

    struct CreateTOCExpected {
        TOCState expectedState;
        AnswerType expectedAnswerType;
        AccountabilityTier expectedTier;
        address expectedCreator;
    }

    struct ResolveTOCParams {
        uint256 tocId;
        address bondToken;
        uint256 bondAmount;
        bytes resolverPayload;
    }

    struct ResolveTOCExpected {
        TOCState expectedState;
        bool expectBondEvent;
        bytes expectedResult;
    }

    struct DisputeParams {
        uint256 tocId;
        address bondToken;
        uint256 bondAmount;
        string reason;
        string evidenceURI;
        bytes proposedResult;
    }

    struct DisputeExpected {
        TOCState expectedState;
        DisputePhase expectedPhase;
        address expectedDisputer;
    }

    struct FeeSplit {
        uint256 protocolFee;
        uint256 tkFee;
        uint256 resolverFee;
    }

    // ============ Fee Calculation Utilities ============

    /// @notice Calculate fee split based on tier
    /// @param registry The registry to query TK share from
    /// @param totalFee The total fee amount
    /// @param tier The accountability tier
    /// @return split The calculated fee split
    function _calculateFeeSplit(
        TOCRegistry registry,
        uint256 totalFee,
        AccountabilityTier tier
    ) internal view returns (FeeSplit memory split) {
        uint256 tkSharePercent = registry.getTKSharePercent(tier);
        split.tkFee = (totalFee * tkSharePercent) / 10000;
        split.protocolFee = totalFee - split.tkFee;
        split.resolverFee = 0; // Not used in current tests
    }

    /// @notice Calculate dispute deadline from current time and window
    /// @param disputeWindow The dispute window duration
    /// @return deadline The calculated deadline (0 if window is 0)
    function _calculateDisputeDeadline(uint256 disputeWindow) internal view returns (uint256 deadline) {
        return disputeWindow > 0 ? block.timestamp + disputeWindow : 0;
    }

    // ============ TOC Creation Helper ============

    /// @notice Create a TOC and verify all effects including events
    /// @dev Captures state before, expects events, executes, and asserts state after
    function _createTocAndVerify(
        TOCRegistry registry,
        CreateTOCParams memory params,
        CreateTOCExpected memory expected
    ) internal returns (uint256 tocId) {
        // Capture state before
        uint256 nextIdBefore = registry.nextTocId();
        uint256 registryBalanceBefore = address(registry).balance;
        uint256 protocolBalanceBefore = registry.getProtocolBalance(FeeCategory.CREATION);
        uint256 tkBalanceBefore = registry.getTKBalance(params.truthKeeper);

        // Calculate expected fee split
        FeeSplit memory fees = _calculateFeeSplit(registry, params.fee, expected.expectedTier);

        // Get resolver trust for event
        ResolverTrust resolverTrust = registry.getResolverTrust(params.resolver);

        // Events are emitted in this order:
        // 1. TruthKeeperApproved (we don't check this one)
        // 2. CreationFeesCollected
        // 3. TOCCreated

        // Expect CreationFeesCollected event
        vm.expectEmit(true, true, true, true);
        emit CreationFeesCollected(nextIdBefore, fees.protocolFee, fees.tkFee, fees.resolverFee);

        // Expect TOCCreated event
        vm.expectEmit(true, true, true, true);
        emit TOCCreated(
            nextIdBefore,
            params.resolver,
            resolverTrust,
            params.templateId,
            expected.expectedAnswerType,
            expected.expectedState,
            params.truthKeeper,
            expected.expectedTier
        );

        // Execute
        tocId = registry.createTOC{value: params.fee}(
            params.resolver,
            params.templateId,
            params.payload,
            params.disputeWindow,
            params.tkWindow,
            params.escalationWindow,
            params.postResolutionWindow,
            params.truthKeeper
        );

        // Assert state after
        assertEq(tocId, nextIdBefore, "TOC ID should match nextTocId before creation");
        assertEq(registry.nextTocId(), nextIdBefore + 1, "nextTocId should increment by 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(expected.expectedState), "TOC state mismatch");
        assertEq(uint8(toc.answerType), uint8(expected.expectedAnswerType), "Answer type mismatch");
        assertEq(toc.resolver, params.resolver, "Resolver mismatch");
        assertEq(toc.disputeWindow, params.disputeWindow, "Dispute window mismatch");
        assertEq(toc.postResolutionWindow, params.postResolutionWindow, "Post resolution window mismatch");
        assertEq(toc.truthKeeper, params.truthKeeper, "TruthKeeper mismatch");
        assertEq(uint8(toc.tierAtCreation), uint8(expected.expectedTier), "Tier mismatch");

        // Verify fee distribution
        assertEq(
            registry.getProtocolBalance(FeeCategory.CREATION),
            protocolBalanceBefore + fees.protocolFee,
            "Protocol balance should increase by protocol fee"
        );
        assertEq(
            registry.getTKBalance(params.truthKeeper),
            tkBalanceBefore + fees.tkFee,
            "TK balance should increase by TK fee"
        );

        // Verify registry received fee (no excess refund in this helper)
        assertEq(
            address(registry).balance,
            registryBalanceBefore + params.fee,
            "Registry balance should increase by fee"
        );
    }

    // ============ Resolution Helper ============

    /// @notice Resolve a TOC and verify all effects including events
    function _resolveTocAndVerify(
        TOCRegistry registry,
        ResolveTOCParams memory params,
        ResolveTOCExpected memory expected
    ) internal {
        // Capture state before
        uint256 registryBalanceBefore = address(registry).balance;
        TOC memory tocBefore = registry.getTOC(params.tocId);

        // Calculate expected dispute deadline
        uint256 expectedDeadline = _calculateDisputeDeadline(tocBefore.disputeWindow);

        // Events differ based on whether TOC is disputable:
        // Disputable: ResolutionBondDeposited (if bond > 0) -> TOCResolutionProposed
        // Undisputable: TOCFinalized only

        if (tocBefore.disputeWindow > 0) {
            // Expect ResolutionBondDeposited event if bond > 0
            if (params.bondAmount > 0) {
                vm.expectEmit(true, true, true, true);
                emit ResolutionBondDeposited(params.tocId, address(this), params.bondToken, params.bondAmount);
            }

            // Expect TOCResolutionProposed event
            vm.expectEmit(true, true, true, true);
            emit TOCResolutionProposed(
                params.tocId,
                address(this),
                tocBefore.answerType,
                expectedDeadline
            );
        } else {
            // Undisputable TOC - goes directly to finalized
            vm.expectEmit(true, true, true, true);
            emit TOCFinalized(params.tocId, tocBefore.answerType);
        }

        // Execute
        registry.resolveTOC{value: params.bondAmount}(
            params.tocId,
            params.bondToken,
            params.bondAmount,
            params.resolverPayload
        );

        // Assert state after
        TOC memory tocAfter = registry.getTOC(params.tocId);
        assertEq(uint8(tocAfter.state), uint8(expected.expectedState), "State mismatch after resolution");

        if (expected.expectedState == TOCState.RESOLVING) {
            assertGt(tocAfter.disputeDeadline, block.timestamp, "Dispute deadline should be in future");
        }

        // Verify bond was stored
        if (params.bondAmount > 0) {
            ResolutionInfo memory resInfo = registry.getResolutionInfo(params.tocId);
            assertEq(resInfo.proposer, address(this), "Proposer should be this contract");
            assertEq(resInfo.bondAmount, params.bondAmount, "Bond amount mismatch");
            assertEq(resInfo.bondToken, params.bondToken, "Bond token mismatch");
        }

        // Verify result was stored
        // Use getOriginalResult for RESOLVING state (proposed result), getResult for RESOLVED state (final result)
        bytes memory storedResult;
        if (expected.expectedState == TOCState.RESOLVING) {
            storedResult = registry.getOriginalResult(params.tocId);
        } else {
            storedResult = registry.getResult(params.tocId);
        }
        assertEq(keccak256(storedResult), keccak256(expected.expectedResult), "Stored result mismatch");

        // Verify ETH bond received
        if (params.bondToken == address(0) && params.bondAmount > 0) {
            assertEq(
                address(registry).balance,
                registryBalanceBefore + params.bondAmount,
                "Registry should receive ETH bond"
            );
        }
    }

    // ============ Dispute Helper ============

    /// @notice Dispute a TOC and verify all effects including events
    function _disputeAndVerify(
        TOCRegistry registry,
        DisputeParams memory params,
        DisputeExpected memory expected
    ) internal {
        // Capture state before
        uint256 registryBalanceBefore = address(registry).balance;

        // Events emitted in order:
        // 1. DisputeBondDeposited
        // 2. TOCDisputed or PostResolutionDisputeFiled

        // Expect DisputeBondDeposited event
        vm.expectEmit(true, true, true, true);
        emit DisputeBondDeposited(params.tocId, expected.expectedDisputer, params.bondToken, params.bondAmount);

        // Expect correct dispute event based on phase
        if (expected.expectedPhase == DisputePhase.POST_RESOLUTION) {
            vm.expectEmit(true, true, true, true);
            emit PostResolutionDisputeFiled(params.tocId, expected.expectedDisputer, params.reason);
        } else {
            vm.expectEmit(true, true, true, true);
            emit TOCDisputed(params.tocId, expected.expectedDisputer, params.reason);
        }

        // Execute
        registry.dispute{value: params.bondAmount}(
            params.tocId,
            params.bondToken,
            params.bondAmount,
            params.reason,
            params.evidenceURI,
            params.proposedResult
        );

        // Assert state after
        TOC memory tocAfter = registry.getTOC(params.tocId);
        assertEq(uint8(tocAfter.state), uint8(expected.expectedState), "State mismatch after dispute");

        // Verify dispute info
        DisputeInfo memory info = registry.getDisputeInfo(params.tocId);
        assertEq(info.disputer, expected.expectedDisputer, "Disputer mismatch");
        assertEq(info.reason, params.reason, "Reason mismatch");
        assertEq(uint8(info.phase), uint8(expected.expectedPhase), "Phase mismatch");
        assertEq(info.bondAmount, params.bondAmount, "Dispute bond amount mismatch");

        // Verify ETH bond received
        if (params.bondToken == address(0)) {
            assertEq(
                address(registry).balance,
                registryBalanceBefore + params.bondAmount,
                "Registry should receive dispute bond"
            );
        }
    }

    // ============ Finalization Helper ============

    /// @notice Finalize a TOC and verify all effects including events
    function _finalizeAndVerify(
        TOCRegistry registry,
        uint256 tocId,
        bytes memory expectedResult
    ) internal {
        // Capture state before
        ResolutionInfo memory resInfo = registry.getResolutionInfo(tocId);
        uint256 registryBalanceBefore = address(registry).balance;
        TOC memory tocBefore = registry.getTOC(tocId);

        // Expect TOCFinalized event
        vm.expectEmit(true, true, true, true);
        emit TOCFinalized(tocId, tocBefore.answerType);

        // Expect ResolutionBondReturned event if bond > 0 and no post-resolution window
        if (resInfo.bondAmount > 0 && tocBefore.postResolutionWindow == 0) {
            vm.expectEmit(true, true, true, true);
            emit ResolutionBondReturned(tocId, resInfo.proposer, resInfo.bondToken, resInfo.bondAmount);
        }

        // Execute
        registry.finalizeTOC(tocId);

        // Assert state after
        TOC memory tocAfter = registry.getTOC(tocId);
        assertEq(uint8(tocAfter.state), uint8(TOCState.RESOLVED), "State should be RESOLVED");

        // Verify result
        bytes memory storedResult = registry.getResult(tocId);
        assertEq(keccak256(storedResult), keccak256(expectedResult), "Final result mismatch");

        // Verify bond handling - bond is ONLY returned if postResolutionWindow == 0
        // When postResolutionWindow > 0, bond is held until window passes without dispute
        if (resInfo.bondAmount > 0 && resInfo.bondToken == address(0)) {
            if (tocAfter.postResolutionWindow == 0) {
                // Bond should be returned
                assertEq(
                    address(registry).balance,
                    registryBalanceBefore - resInfo.bondAmount,
                    "Registry balance should decrease by bond amount (bond returned)"
                );
            } else {
                // Bond should still be held
                assertEq(
                    address(registry).balance,
                    registryBalanceBefore,
                    "Registry balance should stay same (bond held for post-resolution window)"
                );
            }
        }

        // Verify fully finalized if no post-resolution window
        if (tocAfter.postResolutionWindow == 0) {
            assertTrue(registry.isFullyFinalized(tocId), "Should be fully finalized");
        }
    }

    // ============ Dispute Resolution Helper ============

    /// @notice Resolve a dispute and verify all effects
    function _resolveDisputeAndVerify(
        TOCRegistry registry,
        uint256 tocId,
        DisputeResolution resolution,
        bytes memory correctedResult,
        TOCState expectedFinalState
    ) internal {
        // Execute
        registry.resolveDispute(tocId, resolution, correctedResult);

        // Assert state after
        TOC memory tocAfter = registry.getTOC(tocId);
        assertEq(uint8(tocAfter.state), uint8(expectedFinalState), "State mismatch after dispute resolution");

        // Verify result based on resolution type
        bytes memory storedResult = registry.getResult(tocId);
        if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
            assertEq(keccak256(storedResult), keccak256(correctedResult), "Result should be corrected");
            assertTrue(registry.hasCorrectedResult(tocId), "Should have corrected result");
        } else if (resolution == DisputeResolution.REJECT_DISPUTE) {
            // Result should remain unchanged from before dispute
            assertFalse(registry.hasCorrectedResult(tocId), "Should not have corrected result");
        }

        // Verify contested flag
        assertTrue(registry.isContested(tocId), "Should be marked as contested");
    }

    // ============ Revert Expectation Helpers ============

    /// @notice Helper to test that a function reverts
    function _expectRevert(bytes memory expectedError) internal {
        vm.expectRevert(expectedError);
    }

    /// @notice Helper to test that a function reverts with any error
    function _expectRevertAny() internal {
        vm.expectRevert();
    }

    // ============ Utility Helpers ============

    /// @notice Warp time forward
    function _warpForward(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /// @notice Create default create params for simpler tests
    function _defaultCreateParams(
        address resolver,
        bytes memory payload,
        address truthKeeper,
        uint256 fee
    ) internal pure returns (CreateTOCParams memory) {
        return CreateTOCParams({
            resolver: resolver,
            templateId: 0,
            payload: payload,
            disputeWindow: 24 hours,
            tkWindow: 24 hours,
            escalationWindow: 48 hours,
            postResolutionWindow: 24 hours,
            truthKeeper: truthKeeper,
            fee: fee
        });
    }

    /// @notice Create default expected state for ACTIVE TOC
    function _defaultActiveExpected(address creator) internal pure returns (CreateTOCExpected memory) {
        return CreateTOCExpected({
            expectedState: TOCState.ACTIVE,
            expectedAnswerType: AnswerType.BOOLEAN,
            expectedTier: AccountabilityTier.TK_GUARANTEED,
            expectedCreator: creator
        });
    }
}
