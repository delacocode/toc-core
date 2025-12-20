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

    receive() external payable {}
}
