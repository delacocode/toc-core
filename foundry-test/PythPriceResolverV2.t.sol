// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "contracts/TOCRegistry/TOCRegistry.sol";
import "contracts/TOCRegistry/TOCTypes.sol";
import "contracts/resolvers/PythPriceResolverV2.sol";
import "contracts/libraries/TOCResultCodec.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./MockTruthKeeper.sol";

/// @title PythPriceResolverV2Test
/// @notice Tests for PythPriceResolverV2 contract
contract PythPriceResolverV2Test is Test {
    TOCRegistry registry;
    PythPriceResolverV2 resolver;
    MockPyth mockPyth;
    MockTruthKeeper truthKeeperContract;

    address owner;
    address user1;
    address truthKeeper;

    // Pyth price feed IDs (mock)
    bytes32 constant BTC_USD = bytes32(uint256(1));
    bytes32 constant ETH_USD = bytes32(uint256(2));

    uint256 constant MIN_RESOLUTION_BOND = 0.1 ether;
    uint256 constant MIN_DISPUTE_BOND = 0.05 ether;
    uint256 constant PYTH_FEE = 1 wei;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);

        // Deploy MockPyth (validTimePeriod=3600, updateFee=1wei)
        mockPyth = new MockPyth(3600, PYTH_FEE);

        // Deploy registry
        registry = new TOCRegistry();

        // Deploy resolver
        resolver = new PythPriceResolverV2(address(mockPyth), address(registry));

        // Deploy mock TruthKeeper
        truthKeeperContract = new MockTruthKeeper(address(registry));
        truthKeeper = address(truthKeeperContract);

        // Configure registry
        registry.addAcceptableResolutionBond(address(0), MIN_RESOLUTION_BOND);
        registry.addAcceptableDisputeBond(address(0), MIN_DISPUTE_BOND);
        registry.addWhitelistedTruthKeeper(truthKeeper);
        registry.setProtocolFeeStandard(0.001 ether);
        registry.setTKSharePercent(AccountabilityTier.TK_GUARANTEED, 4000);
        registry.registerResolver(address(resolver));

        // Fund resolver for Pyth fees
        vm.deal(address(resolver), 1 ether);
    }

    // ============ Helper Functions ============

    /// @notice Create Pyth price update data for testing
    function _createPriceUpdate(
        bytes32 priceId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint64 publishTime
    ) internal pure returns (bytes memory) {
        PythStructs.PriceFeed memory priceFeed;
        priceFeed.id = priceId;
        priceFeed.price.price = price;
        priceFeed.price.conf = conf;
        priceFeed.price.expo = expo;
        priceFeed.price.publishTime = publishTime;
        priceFeed.emaPrice.price = price;
        priceFeed.emaPrice.conf = conf;
        priceFeed.emaPrice.expo = expo;
        priceFeed.emaPrice.publishTime = publishTime;

        return abi.encode(priceFeed, uint64(0));
    }

    /// @notice Encode price updates as resolver expects
    function _encodePriceUpdates(bytes[] memory updates) internal pure returns (bytes memory) {
        return abi.encode(updates);
    }

    // ============ Base Tests ============

    function test_TemplateConstants() public {
        assertEq(resolver.TEMPLATE_NONE(), 0);
        assertEq(resolver.TEMPLATE_SNAPSHOT(), 1);
        assertEq(resolver.TEMPLATE_RANGE(), 2);
        assertEq(resolver.TEMPLATE_REACHED_TARGET(), 3);
        assertEq(resolver.TEMPLATE_COUNT(), 16);
    }

    function test_TemplateValidation() public {
        assertFalse(resolver.isValidTemplate(0), "Template 0 should be invalid");
        assertTrue(resolver.isValidTemplate(1), "Template 1 should be valid");
        assertTrue(resolver.isValidTemplate(15), "Template 15 should be valid");
        assertFalse(resolver.isValidTemplate(16), "Template 16 should be invalid");
    }

    function test_GetTemplateCount() public {
        assertEq(resolver.getTemplateCount(), 16);
    }

    function test_AllTemplatesReturnBoolean() public {
        for (uint32 i = 1; i < 16; i++) {
            assertEq(uint8(resolver.getTemplateAnswerType(i)), uint8(AnswerType.BOOLEAN));
        }
    }

    function test_RevertInvalidTemplate() public {
        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver),
            0, // TEMPLATE_NONE - invalid
            "",
            0, 0, 0, 0,
            truthKeeper
        ) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert on invalid template");
    }

    // ============ Template 1: Snapshot Tests ============

    function test_CreateSnapshotTOC() public {
        // Payload: priceId, deadline, threshold, isAbove
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
            int64(95000_00000000), // $95,000 with 8 decimals
            true // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1, // TEMPLATE_SNAPSHOT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveSnapshotAbove_True() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create price update: $96,000 at deadline
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000), // conf: $100 (well under 1%)
            int32(-8),
            uint64(deadline)
        );

        // Update mock pyth
        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Resolve
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price above threshold");
    }

    function test_ResolveSnapshotAbove_False() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline);

        // Create price update: $94,000 at deadline (below threshold)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - price below threshold");
    }

    function test_ResolveSnapshotBelow_True() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            false // isAbove = false means isBelow
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline);

        // Price at $94,000 (below threshold)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price below threshold");
    }

    function test_RevertSnapshotBeforeDeadline() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Don't warp - still before deadline
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        bool reverted = false;
        try registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert before deadline");
    }

    function test_RevertSnapshotConfidenceTooWide() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline);

        // Confidence > 1% of price (96000 * 0.01 = 960, we use 2000)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(2000_00000000), // $2000 conf > 1%
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        bool reverted = false;
        try registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert when confidence too wide");
    }

    function test_RevertSnapshotPriceNotNearDeadline() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline + 10); // Past deadline

        // Price publishTime is 5 seconds before deadline (not within 1 sec tolerance)
        // deadline is 86401, so priceTime is 86396
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(86396) // 5 seconds before deadline
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        bool reverted = false;
        try registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert when price not near deadline");
    }

    // ============ Template 2: Range Tests ============

    function test_CreateRangeTOC() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
            int64(90000_00000000), // lower: $90,000
            int64(100000_00000000), // upper: $100,000
            true // isInside
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            2, // TEMPLATE_RANGE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveRangeInside_True() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(90000_00000000),
            int64(100000_00000000),
            true // isInside
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            2,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline);

        // Price at $95,000 (inside range)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(95000_00000000), uint64(100_00000000), int32(-8), uint64(deadline));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - price inside range");
    }

    function test_ResolveRangeInside_False() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(90000_00000000),
            int64(100000_00000000),
            true // isInside
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            2,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline);

        // Price at $105,000 (outside range)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(105000_00000000), uint64(100_00000000), int32(-8), uint64(deadline));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertFalse(result, "Should be false - price outside range");
    }

    function test_ResolveRangeOutside_True() public {
        uint256 deadline = block.timestamp + 1 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(90000_00000000),
            int64(100000_00000000),
            false // isInside = false means isOutside
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            2,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline);

        // Price at $105,000 (outside range)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(105000_00000000), uint64(100_00000000), int32(-8), uint64(deadline));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - price outside range");
    }

    function test_RevertRangeInvalidBounds() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
            int64(100000_00000000), // lower > upper (invalid!)
            int64(90000_00000000),
            true
        );

        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver),
            2,
            payload,
            0, 0, 0, 0,
            truthKeeper
        ) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert with invalid bounds");
    }

    // ============ Template 3: Reached Target Tests ============

    function test_ResolveReachedTargetAbove_Yes() public {
        uint256 deadline = block.timestamp + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000), // target: $100,000
            true // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            3, // TEMPLATE_REACHED_TARGET
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Price hit $101,000 on day 3 (before deadline)
        uint256 hitTime = block.timestamp + 3 days;
        vm.warp(hitTime);

        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(101000_00000000), uint64(100_00000000), int32(-8), uint64(hitTime));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - target was reached before deadline");
    }

    function test_ResolveReachedTargetAbove_No() public {
        uint256 deadline = block.timestamp + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000), // target: $100,000
            true // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            3,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp past deadline
        vm.warp(deadline + 1);

        // Price at deadline was only $95,000 (never reached target)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(95000_00000000), uint64(100_00000000), int32(-8), uint64(deadline));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // For NO resolution, we just need to be past deadline
        // The resolver should accept this and return false
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertFalse(result, "Should be false - target never reached");
    }

    function test_ResolveReachedTargetBelow_Yes() public {
        uint256 deadline = block.timestamp + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(90000_00000000), // target: $90,000
            false // isAbove = false means must go below
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            3,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Price dropped to $89,000 on day 2
        uint256 hitTime = block.timestamp + 2 days;
        vm.warp(hitTime);

        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(89000_00000000), uint64(100_00000000), int32(-8), uint64(hitTime));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - dropped below target");
    }

    function test_RevertReachedTargetPriceAfterDeadline() public {
        uint256 deadline = block.timestamp + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            3,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline + 1 days);

        // Try to use a price from after deadline
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(BTC_USD, int64(101000_00000000), uint64(100_00000000), int32(-8), uint64(deadline + 1 days));

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        bool reverted = false;
        try registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert - price after deadline");
    }

    // ============ Template 4: Touched Both Tests ============

    function test_CreateTouchedBothTOC() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 7 days,
            int64(100000_00000000), // targetA: $100,000 (high target)
            int64(90000_00000000)   // targetB: $90,000 (low target)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            4, // TEMPLATE_TOUCHED_BOTH
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveTouchedBoth_Yes() public {
        uint256 deadline = block.timestamp + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000), // targetA: $100,000
            int64(90000_00000000)   // targetB: $90,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            4,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to after deadline
        vm.warp(deadline + 1);

        // Provide multiple price proofs showing both targets were touched
        bytes[] memory updates = new bytes[](3);

        // Day 2: Price reached $101,000 (>= targetA)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(101000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 5 days)
        );

        // Day 5: Price dropped to $89,000 (<= targetB)
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(89000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 2 days)
        );

        // Day 7 (at deadline): Price at $95,000
        updates[2] = _createPriceUpdate(
            BTC_USD,
            int64(95000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 3}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - both targets were touched");
    }

    function test_ResolveTouchedBoth_No() public {
        uint256 deadline = block.timestamp + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000), // targetA: $100,000
            int64(90000_00000000)   // targetB: $90,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            4,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline + 1);

        // Provide price proofs showing only targetA was touched (not targetB)
        bytes[] memory updates = new bytes[](2);

        // Day 2: Price reached $101,000 (>= targetA) ✓
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(101000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 5 days)
        );

        // Day 7: Price at $95,000 (never touched targetB of $90,000)
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(95000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertFalse(result, "Should be false - only targetA was touched, not both");
    }

    // ============ Template 5: Stayed Tests ============

    function test_CreateStayedTOC() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true,                   // isAbove - must stay above
            startTime
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            5, // TEMPLATE_STAYED
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveStayedAbove_Yes() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true,                   // isAbove - must stay above
            startTime
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            5,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to after deadline
        vm.warp(deadline + 1);

        // Provide multiple price proofs covering the period, ALL above threshold
        bytes[] memory updates = new bytes[](4);

        // Day 0 (start): $96,000 (above)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(startTime)
        );

        // Day 2: $97,000 (above)
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(97000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(startTime + 2 days)
        );

        // Day 5: $98,000 (above)
        updates[2] = _createPriceUpdate(
            BTC_USD,
            int64(98000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(startTime + 5 days)
        );

        // Day 7 (deadline): $96,500 (above)
        updates[3] = _createPriceUpdate(
            BTC_USD,
            int64(96500_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 4}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - all proofs show price stayed above threshold");
    }

    function test_ResolveStayedAbove_No() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true,                   // isAbove - must stay above
            startTime
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            5,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        vm.warp(deadline + 1);

        // Provide proofs where at least ONE is below threshold
        bytes[] memory updates = new bytes[](4);

        // Day 0: $96,000 (above)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(startTime)
        );

        // Day 2: $97,000 (above)
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(97000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(startTime + 2 days)
        );

        // Day 4: $94,000 (BELOW threshold - violated!)
        updates[2] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(startTime + 4 days)
        );

        // Day 7: $96,000 (above again, but too late)
        updates[3] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 4}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertFalse(result, "Should be false - at least one proof violated the condition");
    }

    // ============ Reference Price Tests ============

    function test_SetReferencePrice() public {
        // Create a TOC
        uint256 deadline = block.timestamp + 7 days;
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1, // TEMPLATE_SNAPSHOT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Create price update for reference price
        uint256 refTime = block.timestamp;
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000), // Reference price: $94,000
            uint64(100_00000000),
            int32(-8),
            uint64(refTime)
        );

        // Update mock pyth first
        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Set reference price (anyone can call this)
        resolver.setReferencePrice(tocId, _encodePriceUpdates(updates));

        // Verify the reference price was set by attempting to set it again (should revert)
        bool reverted = false;
        try resolver.setReferencePrice(tocId, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert when reference price already set");
    }

    function test_SetReferencePriceWithTimestamp() public {
        // Create a TOC
        uint256 deadline = block.timestamp + 7 days;
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // For templates with referenceTimestamp, the timestamp must match
        // Since template 1 (Snapshot) doesn't have referenceTimestamp,
        // it will accept any recent price
        uint256 refTime = block.timestamp;
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(refTime)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        resolver.setReferencePrice(tocId, _encodePriceUpdates(updates));

        // Success - reference price was set
        // Verify by trying to set again
        bool reverted = false;
        try resolver.setReferencePrice(tocId, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert when already set");
    }

    function test_RevertSetReferencePriceAlreadySet() public {
        // Create a TOC
        uint256 deadline = block.timestamp + 7 days;
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Set reference price first time
        uint256 refTime = block.timestamp;
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(refTime)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        resolver.setReferencePrice(tocId, _encodePriceUpdates(updates));

        // Try to set reference price again - should revert
        bytes[] memory updates2 = new bytes[](1);
        updates2[0] = _createPriceUpdate(
            BTC_USD,
            int64(95000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(refTime + 100)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates2);

        vm.expectRevert(
            abi.encodeWithSelector(
                PythPriceResolverV2.ReferencePriceAlreadySet.selector,
                tocId
            )
        );
        resolver.setReferencePrice(tocId, _encodePriceUpdates(updates2));
    }

    receive() external payable {}
}
