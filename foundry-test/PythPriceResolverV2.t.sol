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

        // Initialize price feeds so they exist in MockPyth
        _initializePriceFeeds();
    }

    /// @notice Initialize price feeds in MockPyth so they exist for validation
    function _initializePriceFeeds() internal {
        bytes[] memory updates = new bytes[](2);
        updates[0] = _createPriceUpdate(BTC_USD, 50000_00000000, 100_00000000, -8, uint64(block.timestamp));
        updates[1] = _createPriceUpdate(ETH_USD, 3000_00000000, 10_00000000, -8, uint64(block.timestamp));
        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
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

    // ============ Template 5: Stayed Tests (Optimistic Approach) ============

    function test_CreateStayedTOC() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true                    // isAbove - must stay above
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

    function test_ResolveStayedAbove_YesNoProof() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true                    // isAbove - must stay above
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

        // OPTIMISTIC: Resolve with no proof (empty array) → defaults to YES
        bytes[] memory updates = new bytes[](0);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - no counter-proof submitted, optimistic YES");
    }

    function test_ResolveStayedAbove_NoWithCounterProof() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(95000_00000000), // threshold: $95,000
            true                    // isAbove - must stay above
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            5,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Submit counter-proof showing price violated (went below threshold)
        // Price at day 4 (before deadline, within valid time range)
        uint256 violationTime = startTime + 4 days;

        bytes[] memory updates = new bytes[](1);

        // Day 4: $94,000 (BELOW threshold - violation!)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(violationTime)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Warp to after deadline so we can resolve
        vm.warp(deadline + 1);

        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertFalse(result, "Should be false - counter-proof shows violation");
    }

    function test_RevertStayedBeforeDeadline() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(95000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            5,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Don't warp - still before deadline
        // Try to resolve with no proof (optimistic YES)
        bytes[] memory updates = new bytes[](0);

        bool reverted = false;
        try registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates)) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert - can't resolve YES before deadline");
    }

    // ============ Template 6: Stayed In Range Tests (Optimistic Approach) ============

    function test_CreateStayedInRangeTOC() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(90000_00000000), // lowerBound: $90,000
            int64(100000_00000000) // upperBound: $100,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            6, // TEMPLATE_STAYED_IN_RANGE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveStayedInRange_YesNoProof() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(90000_00000000), // lowerBound: $90,000
            int64(100000_00000000) // upperBound: $100,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            6,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to after deadline
        vm.warp(deadline + 1);

        // OPTIMISTIC: Resolve with no proof (empty array) → defaults to YES
        bytes[] memory updates = new bytes[](0);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertTrue(result, "Should be true - no counter-proof submitted, optimistic YES");
    }

    function test_ResolveStayedInRange_NoWithCounterProof() public {
        uint256 startTime = block.timestamp;
        uint256 deadline = startTime + 7 days;

        bytes memory payload = abi.encode(
            BTC_USD,
            startTime,
            deadline,
            int64(90000_00000000), // lowerBound: $90,000
            int64(100000_00000000) // upperBound: $100,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            6,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Submit counter-proof showing price violated (went outside range)
        // Price at day 4 (before deadline, within valid time range)
        uint256 violationTime = startTime + 4 days;

        bytes[] memory updates = new bytes[](1);

        // Day 4: $105,000 (ABOVE upperBound - violation!)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(105000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(violationTime)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Warp to after deadline so we can resolve
        vm.warp(deadline + 1);

        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        bool result = TOCResultCodec.decodeBoolean(registry.getResult(tocId));
        assertFalse(result, "Should be false - counter-proof shows violation (price above upper bound)");
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

    // ============ Template 7: Breakout Tests ============

    function test_CreateBreakoutTOC() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceId, deadline, referenceTimestamp, referencePrice, isUp
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference price
            true // isUp - break above reference
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7, // TEMPLATE_BREAKOUT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveBreakoutUp_Yes() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC with reference price at $95,000
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000),
            true // isUp
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to after reference time but before deadline
        vm.warp(refTime + 2 hours);

        // Create price update showing breakout: $96,000 (above $95,000)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(refTime + 2 hours)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Resolve
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (price broke above reference)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price broke above reference");
    }

    function test_ResolveBreakoutUp_No() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC with reference price at $95,000
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000),
            true // isUp
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to after deadline
        vm.warp(deadline + 1 hours);

        // Resolve with empty proof (no breakout occurred)
        bytes[] memory updates = new bytes[](0);

        // Resolve
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (deadline passed, no breakout proof)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - deadline passed without breakout");
    }

    function test_ResolveBreakoutDown_Yes() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC with reference price at $95,000, break down
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000),
            false // isUp = false (break down)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to after reference time but before deadline
        vm.warp(refTime + 2 hours);

        // Create price update showing breakout down: $94,000 (below $95,000)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(94000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(refTime + 2 hours)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);

        // Resolve
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (price broke below reference)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price broke below reference");
    }

    function test_RevertBreakoutReferencePriceNotSet() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC with referenceTimestamp=0 and referencePrice=0 (will call setReferencePrice later)
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            uint256(0), // referenceTimestamp = 0
            int64(0),   // referencePrice = 0
            true        // isUp
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Try to resolve without setting reference price - should revert
        vm.warp(deadline + 1 hours);
        bytes[] memory updates = new bytes[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PythPriceResolverV2.ReferencePriceNotSet.selector,
                tocId
            )
        );
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));
    }

    function test_BreakoutWithSetReferencePrice() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC with referenceTimestamp and referencePrice both 0
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            uint256(0), // referenceTimestamp = 0
            int64(0),   // referencePrice = 0
            true        // isUp
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Set reference price using setReferencePrice
        bytes[] memory refUpdates = new bytes[](1);
        refUpdates[0] = _createPriceUpdate(
            BTC_USD,
            int64(95000_00000000), // $95,000 reference
            uint64(100_00000000),
            int32(-8),
            uint64(refTime)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(refUpdates);
        resolver.setReferencePrice(tocId, _encodePriceUpdates(refUpdates));

        // Now resolve with breakout proof
        vm.warp(refTime + 2 hours);

        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000), // $96,000 - broke above
            uint64(100_00000000),
            int32(-8),
            uint64(refTime + 2 hours)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price broke above reference");
    }

    // ============ Template 8: Percentage Change Tests ============

    function test_CreatePercentageChangeTOC() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceId, deadline, referenceTimestamp, referencePrice, percentageBps, isUp
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference price
            uint64(1000),          // 10% (1000 bps)
            true                   // isUp - price gain
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            8, // TEMPLATE_PERCENTAGE_CHANGE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolvePercentageChangeUp_Yes() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC gain 10% from $95,000 reference?
        // Target: $95,000 * 1.10 = $104,500
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference
            uint64(1000),          // 10% (1000 bps)
            true                   // isUp
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            8,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $105,000 (gained more than 10%)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(105000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (price gained required %)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price gained 10%+");
    }

    function test_ResolvePercentageChangeUp_No() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC gain 10% from $95,000 reference?
        // Target: $95,000 * 1.10 = $104,500
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference
            uint64(1000),          // 10% (1000 bps)
            true                   // isUp
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            8,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $100,000 (only gained 5.26%, not enough)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(100000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (price didn't gain enough)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - price only gained 5.26%, not 10%");
    }

    function test_ResolvePercentageChangeDown_Yes() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC lose 10% from $95,000 reference?
        // Target: $95,000 * 0.90 = $85,500
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference
            uint64(1000),          // 10% (1000 bps)
            false                  // isUp = false (down)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            8,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $85,000 (lost more than 10%)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(85000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (price lost required %)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price lost 10%+");
    }

    // ============ Template 9: Percentage Either Tests ============

    function test_CreatePercentageEitherTOC() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceId, deadline, referenceTimestamp, referencePrice, percentageBps
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference price
            uint64(1000)           // 10% (1000 bps) in either direction
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            9, // TEMPLATE_PERCENTAGE_EITHER
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolvePercentageEither_YesUp() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC move 10% in either direction from $95,000?
        // Upper threshold: $95,000 * 1.10 = $104,500
        // Lower threshold: $95,000 * 0.90 = $85,500
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference
            uint64(1000)           // 10% (1000 bps)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            9,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $105,000 (moved up more than 10%)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(105000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (price moved up by 10%+)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price moved up 10%+");
    }

    function test_ResolvePercentageEither_YesDown() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC move 10% in either direction from $95,000?
        // Upper threshold: $95,000 * 1.10 = $104,500
        // Lower threshold: $95,000 * 0.90 = $85,500
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference
            uint64(1000)           // 10% (1000 bps)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            9,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $85,000 (moved down more than 10%)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(85000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (price moved down by 10%+)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - price moved down 10%+");
    }

    function test_ResolvePercentageEither_No() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC move 10% in either direction from $95,000?
        // Upper threshold: $95,000 * 1.10 = $104,500
        // Lower threshold: $95,000 * 0.90 = $85,500
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 reference
            uint64(1000)           // 10% (1000 bps)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            9,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $98,000 (only moved 3.16%, not enough in either direction)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(98000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (price didn't move enough in either direction)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - price only moved 3.16%, not 10%");
    }

    // ============ Template 10: End vs Start Tests ============

    function test_CreateEndVsStartTOC() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceId, deadline, referenceTimestamp, referencePrice, isHigher
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 start price
            true                   // isHigher - expect deadline price > start price
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            10, // TEMPLATE_END_VS_START
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveEndVsStartHigher_Yes() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Will BTC price be higher at deadline than start price of $95,000?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 start price
            true                   // isHigher
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            10,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $98,000 (higher than $95,000 start)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(98000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (deadline price > start price)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - deadline price higher than start price");
    }

    function test_ResolveEndVsStartHigher_No() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Will BTC price be higher at deadline than start price of $95,000?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 start price
            true                   // isHigher
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            10,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $92,000 (lower than $95,000 start)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(92000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (deadline price not higher than start price)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - deadline price lower than start price");
    }

    function test_ResolveEndVsStartLower_Yes() public {
        vm.warp(1 days); // Set block.timestamp to a reasonable value
        uint256 refTime = block.timestamp - 1 hours;
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Will BTC price be lower at deadline than start price of $95,000?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            refTime,
            int64(95000_00000000), // $95,000 start price
            false                  // isHigher = false (expect lower)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            10,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Price at deadline: $90,000 (lower than $95,000 start)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(90000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (deadline price < start price)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - deadline price lower than start price");
    }

    // ============ Template 11: Asset Compare Tests ============

    function test_CreateAssetCompareTOC() public {
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceIdA, priceIdB, deadline, aGreater
        bytes memory payload = abi.encode(
            BTC_USD,  // Asset A
            ETH_USD,  // Asset B
            deadline,
            true      // aGreater - expect BTC > ETH
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11, // TEMPLATE_ASSET_COMPARE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveAssetCompareAGreater_Yes() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Will BTC > ETH at deadline?
        bytes memory payload = abi.encode(
            BTC_USD,
            ETH_USD,
            deadline,
            true  // aGreater
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // BTC at $96,000
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        // ETH at $3,500
        updates[1] = _createPriceUpdate(
            ETH_USD,
            int64(3500_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (BTC $96,000 > ETH $3,500)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - BTC price > ETH price");
    }

    function test_ResolveAssetCompareAGreater_No() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Will BTC > ETH at deadline?
        bytes memory payload = abi.encode(
            BTC_USD,
            ETH_USD,
            deadline,
            true  // aGreater
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // BTC at $3,000 (hypothetical low price)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(3000_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // ETH at $3,500
        updates[1] = _createPriceUpdate(
            ETH_USD,
            int64(3500_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (BTC $3,000 < ETH $3,500)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - BTC price < ETH price");
    }

    function test_ResolveAssetCompareALess_Yes() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Will ETH < BTC at deadline? (aGreater=false means expect A < B)
        bytes memory payload = abi.encode(
            ETH_USD,  // Asset A
            BTC_USD,  // Asset B
            deadline,
            false     // aGreater = false (expect A < B)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // ETH at $3,500
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(3500_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // BTC at $96,000
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (ETH $3,500 < BTC $96,000)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - ETH price < BTC price");
    }

    function test_RevertAssetCompareSamePriceIds() public {
        uint256 deadline = block.timestamp + 1 days;

        // Try to create TOC with same priceIds (invalid!)
        bytes memory payload = abi.encode(
            BTC_USD,
            BTC_USD,  // Same as priceIdA - should revert!
            deadline,
            true
        );

        bool reverted = false;
        try registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11,
            payload,
            0, 0, 0, 0,
            truthKeeper
        ) {
            // Should not reach
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert with same price IDs");
    }

    // ============ Template 12: Ratio Threshold Tests ============

    function test_CreateRatioThresholdTOC() public {
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceIdA, priceIdB, deadline, ratioBps, isAbove
        // Example: Is ETH/BTC ratio above 3% (300 bps)?
        bytes memory payload = abi.encode(
            ETH_USD,  // Asset A (numerator)
            BTC_USD,  // Asset B (denominator)
            deadline,
            uint64(300),  // 300 bps = 3%
            true          // isAbove - ratio must be > 3%
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            12, // TEMPLATE_RATIO_THRESHOLD
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveRatioThresholdAbove_Yes() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Is ETH/BTC ratio > 3.5% at deadline?
        bytes memory payload = abi.encode(
            ETH_USD,
            BTC_USD,
            deadline,
            uint64(350),  // 350 bps = 3.5%
            true          // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            12,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // ETH at $3,600
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(3600_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // BTC at $96,000
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        // Ratio = (3600 * 10000) / 96000 = 375 bps = 3.75%
        // 375 > 350, so outcome should be YES

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (ratio 3.75% > threshold 3.5%)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - ratio above threshold");
    }

    function test_ResolveRatioThresholdAbove_No() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Is ETH/BTC ratio > 4% at deadline?
        bytes memory payload = abi.encode(
            ETH_USD,
            BTC_USD,
            deadline,
            uint64(400),  // 400 bps = 4%
            true          // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            12,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // ETH at $3,600
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(3600_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // BTC at $96,000
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        // Ratio = (3600 * 10000) / 96000 = 375 bps = 3.75%
        // 375 < 400, so outcome should be NO

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (ratio 3.75% < threshold 4%)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - ratio below threshold");
    }

    function test_ResolveRatioThresholdBelow_Yes() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Is ETH/BTC ratio < 4% at deadline?
        bytes memory payload = abi.encode(
            ETH_USD,
            BTC_USD,
            deadline,
            uint64(400),  // 400 bps = 4%
            false         // isAbove = false, checking if ratio < threshold
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            12,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // ETH at $3,600
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(3600_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // BTC at $96,000
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        // Ratio = (3600 * 10000) / 96000 = 375 bps = 3.75%
        // 375 < 400, so outcome should be YES

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (ratio 3.75% < threshold 4%)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - ratio below threshold");
    }

    // ============ Template 13: Spread Threshold Tests ============

    function test_CreateSpreadThresholdTOC() public {
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceIdA, priceIdB, deadline, spreadThreshold, isAbove
        // Example: Is BTC-ETH spread above $90,000?
        bytes memory payload = abi.encode(
            BTC_USD,  // Asset A
            ETH_USD,  // Asset B
            deadline,
            int64(90000_00000000),  // $90,000 threshold
            true                     // isAbove - spread must be > $90,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            13, // TEMPLATE_SPREAD_THRESHOLD
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveSpreadThresholdAbove_Yes() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Is BTC-ETH spread > $90,000 at deadline?
        bytes memory payload = abi.encode(
            BTC_USD,
            ETH_USD,
            deadline,
            int64(90000_00000000),  // $90,000 threshold
            true                     // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            13,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // BTC at $96,000
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        // ETH at $3,600
        updates[1] = _createPriceUpdate(
            ETH_USD,
            int64(3600_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // Spread = BTC - ETH = 96000 - 3600 = 92400
        // 92400 > 90000, so outcome should be YES

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (spread $92,400 > threshold $90,000)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - spread above threshold");
    }

    function test_ResolveSpreadThresholdAbove_No() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Is BTC-ETH spread > $95,000 at deadline?
        bytes memory payload = abi.encode(
            BTC_USD,
            ETH_USD,
            deadline,
            int64(95000_00000000),  // $95,000 threshold
            true                     // isAbove
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            13,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Create two price updates at deadline
        bytes[] memory updates = new bytes[](2);

        // BTC at $96,000
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline)
        );

        // ETH at $3,600
        updates[1] = _createPriceUpdate(
            ETH_USD,
            int64(3600_00000000),
            uint64(10_00000000),
            int32(-8),
            uint64(deadline)
        );

        // Spread = BTC - ETH = 96000 - 3600 = 92400
        // 92400 < 95000, so outcome should be NO

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (spread $92,400 < threshold $95,000)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - spread below threshold");
    }

    // ============ Template 14: Flip Tests ============

    function test_CreateFlipTOC() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 referenceTime = block.timestamp;

        // Payload: priceIdA, priceIdB, deadline, referenceTimestamp, referencePriceA, referencePriceB
        // Example: Did ETH overtake (flip above) a lower priced asset before deadline?
        // ETH starts at $3,000, Asset B at $3,500
        bytes memory payload = abi.encode(
            ETH_USD,                    // Asset A
            BTC_USD,                    // Asset B (just for test, normally different pair)
            deadline,
            referenceTime,
            int64(3000_00000000),      // ETH at $3,000
            int64(3500_00000000)       // BTC at $3,500
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            14, // TEMPLATE_FLIP
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveFlip_Yes() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 referenceTime = block.timestamp;

        // Create TOC: Did ETH flip above BTC before deadline?
        // Initially: ETH ($3,000) < BTC ($96,000)
        bytes memory payload = abi.encode(
            ETH_USD,
            BTC_USD,
            deadline,
            referenceTime,
            int64(3000_00000000),      // ETH starts at $3,000
            int64(96000_00000000)      // BTC starts at $96,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            14,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to middle of period
        vm.warp(referenceTime + 12 hours);

        // Create proof showing flip occurred: ETH ($97,000) > BTC ($96,000)
        bytes[] memory updates = new bytes[](2);

        // ETH flipped to $97,000
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(97000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(referenceTime + 12 hours)
        );

        // BTC at $96,000
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(referenceTime + 12 hours)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (flip occurred)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - flip occurred");
    }

    function test_ResolveFlip_No() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 referenceTime = block.timestamp;

        // Create TOC: Did ETH flip above BTC before deadline?
        // Initially: ETH ($3,000) < BTC ($96,000)
        bytes memory payload = abi.encode(
            ETH_USD,
            BTC_USD,
            deadline,
            referenceTime,
            int64(3000_00000000),      // ETH starts at $3,000
            int64(96000_00000000)      // BTC starts at $96,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            14,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp past deadline
        vm.warp(deadline + 1);

        // No proof submitted (empty array) - flip did not occur
        bytes[] memory updates = new bytes[](0);

        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (flip did not occur)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - no flip occurred");
    }

    function test_ResolveFlip_NoProofDoesNotShowFlip() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 referenceTime = block.timestamp;

        // Create TOC: Did ETH flip above BTC before deadline?
        // Initially: ETH ($3,000) < BTC ($96,000)
        bytes memory payload = abi.encode(
            ETH_USD,
            BTC_USD,
            deadline,
            referenceTime,
            int64(3000_00000000),      // ETH starts at $3,000
            int64(96000_00000000)      // BTC starts at $96,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            14,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp past deadline
        vm.warp(deadline + 1);

        // Submit proof but it doesn't show flip: ETH still below BTC
        bytes[] memory updates = new bytes[](2);

        // ETH at $4,000 (still below BTC)
        updates[0] = _createPriceUpdate(
            ETH_USD,
            int64(4000_00000000),
            uint64(10_00000000),   // conf: $10 (well under 1% of $4,000)
            int32(-8),
            uint64(deadline)
        );

        // BTC at $96,000
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),  // conf: $100 (well under 1% of $96,000)
            int32(-8),
            uint64(deadline)
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (proof doesn't show flip)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - no flip in proof");
    }

    // ============ Template 15: First to Target Tests ============

    function test_CreateFirstToTargetTOC() public {
        uint256 deadline = block.timestamp + 1 days;

        // Payload: priceId, deadline, targetA, targetB
        // Example: Did BTC hit $100k before hitting $90k?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000),    // targetA: $100,000 (hit this first = YES)
            int64(90000_00000000)      // targetB: $90,000 (hit this first = NO)
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            15, // TEMPLATE_FIRST_TO_TARGET
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(tocId, 1, "First TOC should have ID 1");

        TOC memory toc = registry.getTOC(tocId);
        assertEq(uint8(toc.state), uint8(TOCState.ACTIVE));
    }

    function test_ResolveFirstToTarget_YesHitA() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC hit $100k before hitting $90k?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000),    // targetA: $100,000
            int64(90000_00000000)      // targetB: $90,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            15,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Submit proof showing targetA was hit first
        // Price hits $100k at T+6 hours, then hits $90k at T+12 hours
        bytes[] memory updates = new bytes[](2);

        // First proof: price at $100k (targetA hit at 6 hours)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(100000_00000000),    // exactly at targetA
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 18 hours)  // 6 hours into the period
        );

        // Second proof: price at $90k (targetB hit at 12 hours)
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(90000_00000000),     // exactly at targetB
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 12 hours)  // 12 hours into the period
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be YES (targetA hit first)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertTrue(result, "Should be true - targetA hit first");
    }

    function test_ResolveFirstToTarget_NoHitB() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC hit $100k before hitting $90k?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000),    // targetA: $100,000
            int64(90000_00000000)      // targetB: $90,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            15,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Submit proof showing targetB was hit first
        // Price hits $90k at T+6 hours, then hits $100k at T+12 hours
        bytes[] memory updates = new bytes[](2);

        // First proof: price at $90k (targetB hit at 6 hours)
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(90000_00000000),     // exactly at targetB
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 18 hours)  // 6 hours into the period
        );

        // Second proof: price at $100k (targetA hit at 12 hours)
        updates[1] = _createPriceUpdate(
            BTC_USD,
            int64(100000_00000000),    // exactly at targetA
            uint64(100_00000000),
            int32(-8),
            uint64(block.timestamp - 12 hours)  // 12 hours into the period
        );

        mockPyth.updatePriceFeeds{value: PYTH_FEE * 2}(updates);
        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (targetB hit first)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - targetB hit first");
    }

    function test_ResolveFirstToTarget_NoDeadlinePassed() public {
        uint256 deadline = block.timestamp + 1 days;

        // Create TOC: Did BTC hit $100k before hitting $90k?
        bytes memory payload = abi.encode(
            BTC_USD,
            deadline,
            int64(100000_00000000),    // targetA: $100,000
            int64(90000_00000000)      // targetB: $90,000
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            15,
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Warp to deadline
        vm.warp(deadline);

        // Submit empty proof array (no target was hit)
        bytes[] memory updates = new bytes[](0);

        registry.resolveTOC(tocId, address(0), 0, _encodePriceUpdates(updates));

        // Check result - should be NO (neither target hit, so targetA not hit first)
        bytes memory resultBytes = registry.getResult(tocId);
        bool result = TOCResultCodec.decodeBoolean(resultBytes);
        assertFalse(result, "Should be false - neither target hit");
    }

    // ============ getTocQuestion Gas Test ============

    function test_GetTocQuestionGas() public {
        uint256 deadline = block.timestamp + 1 days;

        // Test Template 1 (Snapshot)
        {
            bytes memory payload = abi.encode(
                BTC_USD,
                deadline,
                int64(100000_00000000),  // $100,000 threshold
                true                      // isAbove
            );

            uint256 tocId = registry.createTOC{value: 0.001 ether}(
                address(resolver),
                1,  // TEMPLATE_SNAPSHOT
                payload,
                0, 0, 0, 0,
                truthKeeper
            );

            uint256 gasBefore = gasleft();
            string memory question = resolver.getTocQuestion(tocId);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Template 1 (Snapshot) Gas:", gasUsed);
            console.log("Question:", question);
        }

        // Test Template 2 (Range)
        {
            bytes memory payload = abi.encode(
                BTC_USD,
                deadline,
                int64(90000_00000000),   // lowerBound
                int64(110000_00000000),  // upperBound
                true                      // isInside
            );

            uint256 tocId = registry.createTOC{value: 0.001 ether}(
                address(resolver),
                2,  // TEMPLATE_RANGE
                payload,
                0, 0, 0, 0,
                truthKeeper
            );

            uint256 gasBefore = gasleft();
            string memory question = resolver.getTocQuestion(tocId);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Template 2 (Range) Gas:", gasUsed);
            console.log("Question:", question);
        }

        // Test Template 11 (Asset Compare)
        {
            bytes memory payload = abi.encode(
                BTC_USD,
                ETH_USD,
                deadline,
                true  // aGreater
            );

            uint256 tocId = registry.createTOC{value: 0.001 ether}(
                address(resolver),
                11,  // TEMPLATE_ASSET_COMPARE
                payload,
                0, 0, 0, 0,
                truthKeeper
            );

            uint256 gasBefore = gasleft();
            string memory question = resolver.getTocQuestion(tocId);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Template 11 (Asset Compare) Gas:", gasUsed);
            console.log("Question:", question);
        }

        // Test Template 3 (Reached Target)
        {
            bytes memory payload = abi.encode(
                BTC_USD,
                deadline,
                int64(100000_00000000),  // target
                true                      // isAbove
            );

            uint256 tocId = registry.createTOC{value: 0.001 ether}(
                address(resolver),
                3,  // TEMPLATE_REACHED_TARGET
                payload,
                0, 0, 0, 0,
                truthKeeper
            );

            uint256 gasBefore = gasleft();
            string memory question = resolver.getTocQuestion(tocId);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Template 3 (Reached Target) Gas:", gasUsed);
            console.log("Question:", question);
        }
    }

    // ============ Template Name Tests ============

    function test_SetTemplateName() public {
        // Set a template name
        resolver.setTemplateName(1, "BTC Snapshot");

        // Create a TOC with template 1
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
            int64(100000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,  // TEMPLATE_SNAPSHOT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Check that getTocQuestion returns the custom name
        string memory question = resolver.getTocQuestion(tocId);
        assertEq(question, "BTC Snapshot");
    }

    function test_SetTemplateNames_Batch() public {
        // Set multiple template names at once
        uint32[] memory templateIds = new uint32[](3);
        templateIds[0] = 1;
        templateIds[1] = 2;
        templateIds[2] = 3;

        string[] memory names = new string[](3);
        names[0] = "Snapshot Template";
        names[1] = "Range Template";
        names[2] = "Reached Target Template";

        resolver.setTemplateNames(templateIds, names);

        // Create TOCs and verify names
        bytes memory payload1 = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
            int64(100000_00000000),
            true
        );

        uint256 tocId1 = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,
            payload1,
            0, 0, 0, 0,
            truthKeeper
        );

        assertEq(resolver.getTocQuestion(tocId1), "Snapshot Template");
    }

    function test_GetTocQuestion_FallbackToTemplateId() public {
        // Create a TOC without setting a template name
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
            int64(100000_00000000),
            true
        );

        uint256 tocId = registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1,  // TEMPLATE_SNAPSHOT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );

        // Should return template ID as string
        string memory question = resolver.getTocQuestion(tocId);
        assertEq(question, "1");
    }

    function test_SetTemplateName_OnlyOwner() public {
        // Try to set template name from non-owner account
        vm.prank(user1);
        vm.expectRevert("Only owner");
        resolver.setTemplateName(1, "Unauthorized");
    }

    function test_SetTemplateName_InvalidTemplate() public {
        // Try to set name for template 0 (invalid)
        vm.expectRevert("Invalid template");
        resolver.setTemplateName(0, "Invalid");

        // Try to set name for template >= TEMPLATE_COUNT
        vm.expectRevert("Invalid template");
        resolver.setTemplateName(16, "Invalid");
    }

    // ============ Non-Existing Price Feed Tests ============

    bytes32 constant NON_EXISTING_PRICE_ID = bytes32(uint256(999));

    function test_RevertSnapshot_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(100000_00000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            1, // TEMPLATE_SNAPSHOT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertRange_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(40000_00000000),
            int64(60000_00000000)
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            2, // TEMPLATE_RANGE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertReachedTarget_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(100000_00000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            3, // TEMPLATE_REACHED_TARGET
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertTouchedBoth_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(60000_00000000),
            int64(40000_00000000)
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            4, // TEMPLATE_TOUCHED_BOTH
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertStayed_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(100000_00000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            5, // TEMPLATE_STAYED
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertStayedInRange_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(40000_00000000),
            int64(60000_00000000)
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            6, // TEMPLATE_STAYED_IN_RANGE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertBreakout_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(60000_00000000),
            int64(40000_00000000)
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            7, // TEMPLATE_BREAKOUT
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertPercentageChange_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(10_0000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            8, // TEMPLATE_PERCENTAGE_CHANGE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertPercentageEither_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(10_0000)
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            9, // TEMPLATE_PERCENTAGE_EITHER
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertEndVsStart_NonExistingPriceFeed() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            10, // TEMPLATE_END_VS_START
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertAssetCompare_NonExistingPriceFeedA() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            ETH_USD,
            block.timestamp + 1 days,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11, // TEMPLATE_ASSET_COMPARE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertAssetCompare_NonExistingPriceFeedB() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            11, // TEMPLATE_ASSET_COMPARE
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertRatioThreshold_NonExistingPriceFeedA() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            ETH_USD,
            block.timestamp + 1 days,
            int64(15_000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            12, // TEMPLATE_RATIO_THRESHOLD
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertRatioThreshold_NonExistingPriceFeedB() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(15_000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            12, // TEMPLATE_RATIO_THRESHOLD
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertSpreadThreshold_NonExistingPriceFeedA() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            ETH_USD,
            block.timestamp + 1 days,
            int64(1000_00000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            13, // TEMPLATE_SPREAD_THRESHOLD
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertSpreadThreshold_NonExistingPriceFeedB() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(1000_00000000),
            true
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            13, // TEMPLATE_SPREAD_THRESHOLD
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertFlip_NonExistingPriceFeedA() public {
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            ETH_USD,
            block.timestamp + 1 days
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            14, // TEMPLATE_FLIP
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertFlip_NonExistingPriceFeedB() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            14, // TEMPLATE_FLIP
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    function test_RevertFirstToTarget_NonExistingPriceFeed() public {
        // FirstToTarget has single priceId with two targets (targetA, targetB)
        bytes memory payload = abi.encode(
            NON_EXISTING_PRICE_ID,
            block.timestamp + 1 days,
            int64(100000_00000000),  // targetA
            int64(40000_00000000)    // targetB
        );

        vm.expectRevert(abi.encodeWithSelector(PythPriceResolverV2.PriceFeedNotFound.selector, NON_EXISTING_PRICE_ID));
        registry.createTOC{value: 0.001 ether}(
            address(resolver),
            15, // TEMPLATE_FIRST_TO_TARGET
            payload,
            0, 0, 0, 0,
            truthKeeper
        );
    }

    receive() external payable {}
}
