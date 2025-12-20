# Pyth Price Resolver Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a production-ready PythPriceResolver with 15 standardized templates for crypto price-based TOCs.

**Architecture:** Complete rewrite of existing PythPriceResolver. Templates use flags to combine similar conditions (above/below). All prices normalized to 8 decimals. Uses Pyth's MockPyth for testing.

**Tech Stack:** Solidity 0.8.29, Foundry, Pyth SDK, forge-std

---

## Task 1: Create Base Contract Structure

**Files:**
- Create: `contracts/resolvers/PythPriceResolverV2.sol`

**Step 1: Create the contract skeleton with constants and immutables**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "../TOCRegistry/ITOCResolver.sol";
import "../TOCRegistry/ITOCRegistry.sol";
import "../TOCRegistry/TOCTypes.sol";
import "../libraries/TOCResultCodec.sol";

/// @title PythPriceResolverV2
/// @notice Professional-grade resolver for crypto price-based TOCs using Pyth oracle
/// @dev Implements 15 standardized templates for price conditions
contract PythPriceResolverV2 is ITOCResolver {
    // ============ Constants ============

    uint32 public constant TEMPLATE_NONE = 0;
    uint32 public constant TEMPLATE_SNAPSHOT = 1;
    uint32 public constant TEMPLATE_RANGE = 2;
    uint32 public constant TEMPLATE_REACHED_TARGET = 3;
    uint32 public constant TEMPLATE_TOUCHED_BOTH = 4;
    uint32 public constant TEMPLATE_STAYED = 5;
    uint32 public constant TEMPLATE_STAYED_IN_RANGE = 6;
    uint32 public constant TEMPLATE_BREAKOUT = 7;
    uint32 public constant TEMPLATE_PERCENTAGE_CHANGE = 8;
    uint32 public constant TEMPLATE_PERCENTAGE_EITHER = 9;
    uint32 public constant TEMPLATE_END_VS_START = 10;
    uint32 public constant TEMPLATE_ASSET_COMPARE = 11;
    uint32 public constant TEMPLATE_RATIO_THRESHOLD = 12;
    uint32 public constant TEMPLATE_SPREAD_THRESHOLD = 13;
    uint32 public constant TEMPLATE_FLIP = 14;
    uint32 public constant TEMPLATE_FIRST_TO_TARGET = 15;
    uint32 public constant TEMPLATE_COUNT = 16;

    /// @notice Maximum confidence as percentage of price (1% = 100 basis points)
    uint64 public constant MAX_CONFIDENCE_BPS = 100;

    /// @notice Tolerance for point-in-time resolution (1 second)
    uint256 public constant POINT_IN_TIME_TOLERANCE = 1;

    /// @notice Standard price decimals (8 decimals like Pyth USD pairs)
    int32 public constant PRICE_DECIMALS = 8;

    // ============ Immutables ============

    IPyth public immutable pyth;
    ITOCRegistry public immutable registry;

    // ============ Storage ============

    mapping(uint256 => uint32) private _tocTemplates;
    mapping(uint256 => bytes) private _tocPayloads;

    // ============ Errors ============

    error InvalidTemplate(uint32 templateId);
    error InvalidPriceId();
    error DeadlineInPast();
    error InvalidBounds();
    error InvalidPercentage();
    error SamePriceIds();
    error DeadlineNotReached(uint256 deadline, uint256 current);
    error PriceNotNearDeadline(uint256 publishTime, uint256 deadline);
    error PriceAfterDeadline(uint256 publishTime, uint256 deadline);
    error ConfidenceTooWide(uint64 confidence, int64 price);
    error TocNotManaged(uint256 tocId);
    error OnlyRegistry();
    error InvalidPayload();
    error InvalidProofArray();
    error ConditionNotMet();

    // ============ Modifiers ============

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) {
            revert OnlyRegistry();
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _pyth, address _registry) {
        pyth = IPyth(_pyth);
        registry = ITOCRegistry(_registry);
    }

    // ============ ITOCResolver Implementation (stubs) ============

    function isTocManaged(uint256 tocId) external view returns (bool) {
        return _tocTemplates[tocId] != TEMPLATE_NONE;
    }

    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (TOCState initialState) {
        if (templateId == TEMPLATE_NONE || templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }
        _tocTemplates[tocId] = templateId;
        _tocPayloads[tocId] = payload;
        return TOCState.ACTIVE;
    }

    function resolveToc(
        uint256 tocId,
        address,
        bytes calldata
    ) external onlyRegistry returns (bytes memory result) {
        if (_tocTemplates[tocId] == TEMPLATE_NONE) {
            revert TocNotManaged(tocId);
        }
        // Stub - will be implemented per template
        return TOCResultCodec.encodeBoolean(false);
    }

    function getTocDetails(
        uint256 tocId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        return (_tocTemplates[tocId], _tocPayloads[tocId]);
    }

    function getTocQuestion(uint256 tocId) external view returns (string memory) {
        if (_tocTemplates[tocId] == TEMPLATE_NONE) {
            return "Unknown TOC";
        }
        return "Price question"; // Stub
    }

    function getTemplateCount() external pure returns (uint32) {
        return TEMPLATE_COUNT;
    }

    function isValidTemplate(uint32 templateId) external pure returns (bool) {
        return templateId > TEMPLATE_NONE && templateId < TEMPLATE_COUNT;
    }

    function getTemplateAnswerType(uint32) external pure returns (AnswerType) {
        return AnswerType.BOOLEAN;
    }

    // ============ Receive ============

    receive() external payable {}
}
```

**Step 2: Verify it compiles**

Run: `forge build`
Expected: Compilation successful

**Step 3: Commit**

```bash
git add contracts/resolvers/PythPriceResolverV2.sol
git commit -m "feat: add PythPriceResolverV2 base structure"
```

---

## Task 2: Create Test Harness

**Files:**
- Create: `foundry-test/PythPriceResolverV2.t.sol`

**Step 1: Create the test file with setup**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "contracts/TOCRegistry/TOCRegistry.sol";
import "contracts/TOCRegistry/TOCTypes.sol";
import "contracts/resolvers/PythPriceResolverV2.sol";
import "contracts/libraries/TOCResultCodec.sol";
import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
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

    receive() external payable {}
}
```

**Step 2: Run tests to verify setup**

Run: `forge test --match-contract PythPriceResolverV2Test -v`
Expected: All tests pass

**Step 3: Commit**

```bash
git add foundry-test/PythPriceResolverV2.t.sol
git commit -m "test: add PythPriceResolverV2 test harness"
```

---

## Task 3: Implement Template 1 - Snapshot

**Files:**
- Modify: `foundry-test/PythPriceResolverV2.t.sol`
- Modify: `contracts/resolvers/PythPriceResolverV2.sol`

**Step 1: Write failing tests for Snapshot template**

Add to test file:

```solidity
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

        vm.warp(deadline + 10); // Past deadline

        // Price publishTime is 5 seconds before deadline (not within 1 sec tolerance)
        bytes[] memory updates = new bytes[](1);
        updates[0] = _createPriceUpdate(
            BTC_USD,
            int64(96000_00000000),
            uint64(100_00000000),
            int32(-8),
            uint64(deadline - 5) // 5 seconds before deadline
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
```

**Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_.*Snapshot.* -v`
Expected: Tests fail (implementation missing)

**Step 3: Implement Snapshot template in resolver**

Add to `PythPriceResolverV2.sol`:

```solidity
    // ============ Events ============

    event SnapshotTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 threshold,
        bool isAbove,
        uint256 deadline
    );

    event TOCResolved(
        uint256 indexed tocId,
        uint32 indexed templateId,
        bool outcome,
        int64 priceUsed,
        uint256 publishTime
    );

    // ============ Structs ============

    struct SnapshotPayload {
        bytes32 priceId;
        uint256 deadline;
        int64 threshold;
        bool isAbove;
    }
```

Update `onTocCreated`:

```solidity
    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (TOCState initialState) {
        if (templateId == TEMPLATE_NONE || templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }

        _tocTemplates[tocId] = templateId;
        _tocPayloads[tocId] = payload;

        // Validate and emit events based on template
        if (templateId == TEMPLATE_SNAPSHOT) {
            _validateAndEmitSnapshot(tocId, payload);
        }

        return TOCState.ACTIVE;
    }

    function _validateAndEmitSnapshot(uint256 tocId, bytes calldata payload) internal {
        SnapshotPayload memory p = abi.decode(payload, (SnapshotPayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit SnapshotTOCCreated(tocId, p.priceId, p.threshold, p.isAbove, p.deadline);
    }
```

Update `resolveToc`:

```solidity
    function resolveToc(
        uint256 tocId,
        address,
        bytes calldata pythUpdateData
    ) external onlyRegistry returns (bytes memory result) {
        uint32 templateId = _tocTemplates[tocId];
        if (templateId == TEMPLATE_NONE) {
            revert TocNotManaged(tocId);
        }

        bool outcome;
        if (templateId == TEMPLATE_SNAPSHOT) {
            outcome = _resolveSnapshot(tocId, pythUpdateData);
        } else {
            revert InvalidTemplate(templateId);
        }

        return TOCResultCodec.encodeBoolean(outcome);
    }

    function _resolveSnapshot(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        SnapshotPayload memory p = abi.decode(_tocPayloads[tocId], (SnapshotPayload));

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get and validate price
        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Check condition
        bool outcome;
        if (p.isAbove) {
            outcome = price > p.threshold;
        } else {
            outcome = price < p.threshold;
        }

        emit TOCResolved(tocId, TEMPLATE_SNAPSHOT, outcome, price, publishTime);
        return outcome;
    }

    function _getPriceAtDeadline(
        bytes32 priceId,
        uint256 deadline,
        bytes calldata pythUpdateData
    ) internal returns (int64 price, uint256 publishTime) {
        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // Update Pyth
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Get price
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceId,
            3600 // Allow fetching recent price
        );

        // Validate timing - must be within 1 second of deadline
        if (priceData.publishTime < deadline || priceData.publishTime > deadline + POINT_IN_TIME_TOLERANCE) {
            revert PriceNotNearDeadline(priceData.publishTime, deadline);
        }

        // Validate confidence (must be < 1% of price)
        _checkConfidence(priceData.conf, priceData.price);

        // Normalize to 8 decimals
        price = _normalizePrice(priceData.price, priceData.expo);
        publishTime = priceData.publishTime;
    }

    function _checkConfidence(uint64 conf, int64 price) internal pure {
        // conf * 100 > |price| means conf > 1% of price
        int64 absPrice = price < 0 ? -price : price;
        if (conf * 100 > uint64(absPrice)) {
            revert ConfidenceTooWide(conf, price);
        }
    }

    function _normalizePrice(int64 price, int32 expo) internal pure returns (int64) {
        // Normalize to 8 decimals
        if (expo == PRICE_DECIMALS) {
            return price;
        } else if (expo < PRICE_DECIMALS) {
            // Need to multiply
            int32 diff = PRICE_DECIMALS - expo;
            return price * int64(int256(10 ** uint32(diff)));
        } else {
            // Need to divide
            int32 diff = expo - PRICE_DECIMALS;
            return price / int64(int256(10 ** uint32(diff)));
        }
    }
```

**Step 4: Run tests to verify they pass**

Run: `forge test --match-test test_.*Snapshot.* -v`
Expected: All Snapshot tests pass

**Step 5: Commit**

```bash
git add contracts/resolvers/PythPriceResolverV2.sol foundry-test/PythPriceResolverV2.t.sol
git commit -m "feat: implement Template 1 (Snapshot) with tests"
```

---

## Task 4: Implement Template 2 - Range

**Files:**
- Modify: `foundry-test/PythPriceResolverV2.t.sol`
- Modify: `contracts/resolvers/PythPriceResolverV2.sol`

**Step 1: Write failing tests for Range template**

Add to test file:

```solidity
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
```

**Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_.*Range.* -v`
Expected: Tests fail

**Step 3: Implement Range template**

Add struct and event:

```solidity
    struct RangePayload {
        bytes32 priceId;
        uint256 deadline;
        int64 lowerBound;
        int64 upperBound;
        bool isInside;
    }

    event RangeTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 lowerBound,
        int64 upperBound,
        bool isInside,
        uint256 deadline
    );
```

Add validation and resolution:

```solidity
    function _validateAndEmitRange(uint256 tocId, bytes calldata payload) internal {
        RangePayload memory p = abi.decode(payload, (RangePayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();
        if (p.lowerBound >= p.upperBound) revert InvalidBounds();

        emit RangeTOCCreated(tocId, p.priceId, p.lowerBound, p.upperBound, p.isInside, p.deadline);
    }

    function _resolveRange(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        RangePayload memory p = abi.decode(_tocPayloads[tocId], (RangePayload));

        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        bool inRange = price >= p.lowerBound && price <= p.upperBound;
        bool outcome = p.isInside ? inRange : !inRange;

        emit TOCResolved(tocId, TEMPLATE_RANGE, outcome, price, publishTime);
        return outcome;
    }
```

Update `onTocCreated` to handle Range:

```solidity
        } else if (templateId == TEMPLATE_RANGE) {
            _validateAndEmitRange(tocId, payload);
        }
```

Update `resolveToc` to handle Range:

```solidity
        } else if (templateId == TEMPLATE_RANGE) {
            outcome = _resolveRange(tocId, pythUpdateData);
        }
```

**Step 4: Run tests**

Run: `forge test --match-test test_.*Range.* -v`
Expected: All Range tests pass

**Step 5: Commit**

```bash
git add contracts/resolvers/PythPriceResolverV2.sol foundry-test/PythPriceResolverV2.t.sol
git commit -m "feat: implement Template 2 (Range) with tests"
```

---

## Task 5: Implement Template 3 - Reached Target

**Files:**
- Modify: `foundry-test/PythPriceResolverV2.t.sol`
- Modify: `contracts/resolvers/PythPriceResolverV2.sol`

**Step 1: Write failing tests**

```solidity
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
```

**Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_.*ReachedTarget.* -v`
Expected: Tests fail

**Step 3: Implement Reached Target template**

```solidity
    struct ReachedTargetPayload {
        bytes32 priceId;
        uint256 deadline;
        int64 target;
        bool isAbove;
    }

    event ReachedTargetTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 target,
        bool isAbove,
        uint256 deadline
    );

    function _validateAndEmitReachedTarget(uint256 tocId, bytes calldata payload) internal {
        ReachedTargetPayload memory p = abi.decode(payload, (ReachedTargetPayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit ReachedTargetTOCCreated(tocId, p.priceId, p.target, p.isAbove, p.deadline);
    }

    function _resolveReachedTarget(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        ReachedTargetPayload memory p = abi.decode(_tocPayloads[tocId], (ReachedTargetPayload));

        (int64 price, uint256 publishTime) = _getPriceBeforeDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Check if target was reached
        bool reached;
        if (p.isAbove) {
            reached = price >= p.target;
        } else {
            reached = price <= p.target;
        }

        // If reached, resolve YES
        if (reached) {
            emit TOCResolved(tocId, TEMPLATE_REACHED_TARGET, true, price, publishTime);
            return true;
        }

        // If not reached and deadline passed, resolve NO
        if (block.timestamp >= p.deadline) {
            emit TOCResolved(tocId, TEMPLATE_REACHED_TARGET, false, price, publishTime);
            return false;
        }

        // Not reached and deadline not passed - can't resolve yet
        revert DeadlineNotReached(p.deadline, block.timestamp);
    }

    function _getPriceBeforeDeadline(
        bytes32 priceId,
        uint256 deadline,
        bytes calldata pythUpdateData
    ) internal returns (int64 price, uint256 publishTime) {
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceId,
            3600
        );

        // For "before deadline" templates, publishTime must be <= deadline
        if (priceData.publishTime > deadline) {
            revert PriceAfterDeadline(priceData.publishTime, deadline);
        }

        _checkConfidence(priceData.conf, priceData.price);

        price = _normalizePrice(priceData.price, priceData.expo);
        publishTime = priceData.publishTime;
    }
```

**Step 4: Update routing in onTocCreated and resolveToc**

**Step 5: Run tests**

Run: `forge test --match-test test_.*ReachedTarget.* -v`
Expected: All tests pass

**Step 6: Commit**

```bash
git add contracts/resolvers/PythPriceResolverV2.sol foundry-test/PythPriceResolverV2.t.sol
git commit -m "feat: implement Template 3 (Reached Target) with tests"
```

---

## Task 6-15: Implement Remaining Templates

Follow the same TDD pattern for templates 4-15:

**Task 6:** Template 4 - Touched Both
**Task 7:** Template 5 - Stayed
**Task 8:** Template 6 - Stayed In Range
**Task 9:** Template 7 - Breakout
**Task 10:** Template 8 - Percentage Change
**Task 11:** Template 9 - Percentage Either
**Task 12:** Template 10 - End vs Start
**Task 13:** Template 11 - Asset Compare
**Task 14:** Template 12 - Ratio Threshold
**Task 15:** Template 13 - Spread Threshold
**Task 16:** Template 14 - Flip
**Task 17:** Template 15 - First to Target

For each:
1. Write failing tests
2. Run to verify failure
3. Implement struct, event, validation, resolution
4. Run tests to verify pass
5. Commit

---

## Task 18: Implement getTocQuestion for All Templates

**Files:**
- Modify: `contracts/resolvers/PythPriceResolverV2.sol`
- Modify: `foundry-test/PythPriceResolverV2.t.sol`

**Step 1: Write tests for question generation**

```solidity
    function test_GetSnapshotQuestion() public {
        bytes memory payload = abi.encode(
            BTC_USD,
            block.timestamp + 1 days,
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

        string memory question = registry.getTocQuestion(tocId);
        assertTrue(bytes(question).length > 0, "Question should not be empty");
        assertTrue(_contains(question, "above"), "Should mention above");
    }
```

**Step 2: Implement question formatting**

Add string helpers and implement `getTocQuestion` for each template.

**Step 3: Run tests and commit**

---

## Task 19: Run Full Test Suite and Fix Issues

**Step 1: Run all tests**

Run: `forge test --match-contract PythPriceResolverV2Test -v`

**Step 2: Fix any failing tests**

**Step 3: Run gas report**

Run: `forge test --match-contract PythPriceResolverV2Test --gas-report`

**Step 4: Commit final version**

```bash
git add .
git commit -m "feat: complete PythPriceResolverV2 with all 15 templates"
```

---

## Task 20: Delete Old Resolver (Optional)

Once V2 is verified working, optionally delete the old `PythPriceResolver.sol`:

```bash
git rm contracts/resolvers/PythPriceResolver.sol
git commit -m "chore: remove deprecated PythPriceResolver v1"
```

---

## Summary

- **Total Tasks:** 20
- **Templates:** 15 (1-15)
- **Test Coverage:** Each template has creation, resolution (success/fail), and edge case tests
- **Key Features:** 1% confidence check, 1-second timing tolerance, 8-decimal normalization, detailed events
