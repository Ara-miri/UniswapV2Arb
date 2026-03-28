// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UniswapV2Arb} from "../src/UniswapV2Arb.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20, MockRouter, RevertingRouter} from "./Mocks.sol";

contract UniswapV2ArbTest is Test {
    UniswapV2Arb internal arb;
    MockERC20 internal baseAsset;
    MockERC20 internal token1;
    MockERC20 internal token2;
    MockERC20 internal token3;
    MockERC20 internal token4;
    MockERC20 internal stable1;
    MockRouter internal router; // 2x
    MockRouter internal routerHalf; // 0.5x
    MockRouter internal router06; // 0.6x

    address internal owner = address(this);
    address internal alice = makeAddr("alice");

    receive() external payable {}

    function setUp() public {
        arb = new UniswapV2Arb(owner);
        baseAsset = new MockERC20("WETH", "WETH");
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        token3 = new MockERC20("Token3", "TK3");
        token4 = new MockERC20("Token4", "TK4");
        stable1 = new MockERC20("USDC", "USDC");
        router = new MockRouter(2, 1);
        routerHalf = new MockRouter(1, 2);
        router06 = new MockRouter(6, 10);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _addPath(address t1, address s, address t2) internal {
        arb.addPath(t1, s, t2);
    }

    /// Seeds router with enough output tokens to settle all 4 hops at 2x rate
    function _fundRouter2x(uint256 amount) internal {
        token1.mint(address(router), amount * 2); // baseAsset → token1
        stable1.mint(address(router), amount * 4); // token1 → stable1
        token2.mint(address(router), amount * 8); // stable1 → token2
        baseAsset.mint(address(router), amount * 16); // token2 → baseAsset
    }

    // ── addPath ───────────────────────────────────────────────────────────────

    function test_AddPath_StoresPath() public {
        _addPath(address(token1), address(stable1), address(token2));
        (address t1, address s, address t2) = arb.paths(0);
        assertEq(t1, address(token1));
        assertEq(s, address(stable1));
        assertEq(t2, address(token2));
    }

    function testRevert_AddPath_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.addPath(address(token1), address(stable1), address(token2));
    }

    function test_AddPath_AppendMultiple() public {
        _addPath(address(token1), address(stable1), address(token2));
        _addPath(address(token2), address(stable1), address(token1));
        (address t1, , ) = arb.paths(0);
        (address t2, , ) = arb.paths(1);
        assertEq(t1, address(token1));
        assertEq(t2, address(token2));
    }

    function test_AddPath_TracksLength() public {
        assertEq(arb.pathsLength(), 0);
        _addPath(address(token1), address(stable1), address(token2));
        assertEq(arb.pathsLength(), 1);
        _addPath(address(token2), address(stable1), address(token1));
        assertEq(arb.pathsLength(), 2);
    }

    // ── findPath ──────────────────────────────────────────────────────────────

    function test_FindPath_ReturnsProfitablePath() public {
        _addPath(address(token1), address(stable1), address(token2));
        // 2x each hop: 1 → 2 → 4 → 8 → 16, clearly profitable
        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            address(router),
            address(baseAsset),
            1 ether
        );
        assertGt(amtBack, 1 ether);
        assertEq(t1, address(token1));
        assertEq(s, address(stable1));
        assertEq(t2, address(token2));
    }

    function test_FindPath_ReturnsZeroWhenUnprofitable() public {
        _addPath(address(token1), address(stable1), address(token2));
        // 0.5x each hop: always a loss
        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            address(routerHalf),
            address(baseAsset),
            1 ether
        );
        assertEq(amtBack, 0);
        assertEq(t1, address(0));
        assertEq(s, address(0));
        assertEq(t2, address(0));
    }

    function test_FindPath_ReturnsZeroWhenNoPaths() public view {
        // No paths registered
        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            address(router),
            address(baseAsset),
            1 ether
        );
        assertEq(amtBack, 0);
        assertEq(t1, address(0));
        assertEq(s, address(0));
        assertEq(t2, address(0));
    }

    function test_FindPath_ReturnsFirstProfitablePath() public {
        // First path is unprofitable, second is profitable
        _addPath(address(token2), address(stable1), address(token1)); // will lose with routerHalf
        _addPath(address(token1), address(stable1), address(token2)); // will profit with router

        // Use a mixed setup: first path loses, second wins
        // We use router (2x) for this test — both paths go through same router
        // so first profitable one found should be returned
        (uint256 amtBack, address t1, , ) = arb.findPath(
            address(router),
            address(baseAsset),
            1 ether
        );
        assertGt(amtBack, 1 ether);
        // First path is found profitable, token2 is t1
        assertEq(t1, address(token2));
    }

    function test_FindPath_RouterReverts_ReturnsZero() public {
        _addPath(address(token1), address(stable1), address(token2));
        RevertingRouter bad = new RevertingRouter();
        (uint256 amtBack, , , ) = arb.findPath(
            address(bad),
            address(baseAsset),
            1 ether
        );
        assertEq(amtBack, 0);
    }

    function test_FindPath_MultiplePaths_StopsAtFirst() public {
        // Register 3 paths, all profitable — should return after first match
        _addPath(address(token1), address(stable1), address(token2));
        _addPath(address(token2), address(stable1), address(token1));
        _addPath(address(token1), address(stable1), address(token1));

        (uint256 amtBack, address t1, , ) = arb.findPath(
            address(router),
            address(baseAsset),
            1 ether
        );
        assertGt(amtBack, 1 ether);
        assertEq(t1, address(token1)); // stopped at first path
    }

    // ── tradePath ─────────────────────────────────────────────────────────────

    function test_TradePath_Profitable() public {
        uint256 amount = 1 ether;
        baseAsset.mint(address(arb), amount);
        _fundRouter2x(amount);

        uint256 before = baseAsset.balanceOf(address(arb));

        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        arb.tradePath(
            address(router),
            address(baseAsset),
            address(token1),
            address(stable1),
            address(token2),
            amount
        );
        assertGt(baseAsset.balanceOf(address(arb)), before);
    }

    function testRevert_TradePath_RevertsIfUnprofitable() public {
        uint256 amount = 10 ether;
        baseAsset.mint(address(arb), amount);

        // Seed routerHalf with enough tokens (0.5x each hop — always a loss)
        token1.mint(address(routerHalf), amount);
        stable1.mint(address(routerHalf), amount);
        token2.mint(address(routerHalf), amount);
        baseAsset.mint(address(routerHalf), amount);

        address[] memory r = new address[](1);
        r[0] = address(routerHalf);
        arb.addRouters(r);

        vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
        arb.tradePath(
            address(routerHalf),
            address(baseAsset),
            address(token1),
            address(stable1),
            address(token2),
            amount
        );
    }

    function testRevert_TradePath_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.tradePath(
            address(router),
            address(baseAsset),
            address(token1),
            address(stable1),
            address(token2),
            1 ether
        );
    }

    function test_TradePath_OnlyDeltasAreTraded() public {
        uint256 amount = 1 ether;
        baseAsset.mint(address(arb), amount);
        _fundRouter2x(amount);

        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        // Pre-existing intermediate balances — only deltas should flow through
        token1.mint(address(arb), 50 ether);
        stable1.mint(address(arb), 50 ether);
        token2.mint(address(arb), 50 ether);

        arb.tradePath(
            address(router),
            address(baseAsset),
            address(token1),
            address(stable1),
            address(token2),
            amount
        );
    }

    // ── addRouters ────────────────────────────────────────────────────────────

    function test_AddRouters_StoresRouters() public {
        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(routerHalf);
        arb.addRouters(r);
        assertEq(arb.routers(0), address(router));
        assertEq(arb.routers(1), address(routerHalf));
    }

    function testRevert_AddRouters_OnlyOwner() public {
        address[] memory r = new address[](1);
        r[0] = address(router);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.addRouters(r);
    }

    function testRevert_AddRouters_RevertsIfDuplicateRouterAdded() public {
        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterAlreadyRegistered.selector,
                address(router)
            )
        );
        arb.addRouters(r);
    }

    function testRevert_AddRouters_RevertsIfDuplicateWithinSameBatch() public {
        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(router); // duplicate in same call

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterAlreadyRegistered.selector,
                address(router)
            )
        );
        arb.addRouters(r);
    }

    function testRevert_AddRouters_RevertsIfDuplicateAcrossBatches() public {
        address[] memory r1 = new address[](1);
        r1[0] = address(router);
        arb.addRouters(r1);

        address[] memory r2 = new address[](2);
        r2[0] = address(routerHalf);
        r2[1] = address(router); // already registered in previous batch

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterAlreadyRegistered.selector,
                address(router)
            )
        );
        arb.addRouters(r2);
    }

    // ── getAmountOutMin ───────────────────────────────────────────────────────

    function test_GetAmountOutMin_BasicRate() public view {
        uint256 result = arb.getAmountOutMin(
            address(router),
            address(token1),
            address(token2),
            1 ether
        );
        assertEq(result, 2 ether);
    }

    function test_GetAmountOutMin_ReturnsZeroOnRevert() public {
        // UniswapV2ArbRouter wraps getAmountsOut in try/catch — should return 0 instead of reverting
        RevertingRouter bad = new RevertingRouter();
        uint256 result = arb.getAmountOutMin(
            address(bad),
            address(token1),
            address(token2),
            1 ether
        );
        assertEq(result, 0);
    }

    function test_GetAmountOutMin_ZeroAmount() public view {
        uint256 result = arb.getAmountOutMin(
            address(router),
            address(token1),
            address(token2),
            0
        );
        assertEq(result, 0);
    }

    // ── estimateDualDexTrade ──────────────────────────────────────────────────

    function test_EstimateDualDexTrade_Profitable() public view {
        // router (2x) then routerHalf (0.5x) on way back — but we use router both ways: net 4x
        uint256 result = arb.estimateDualDexTrade(
            address(router),
            address(router06),
            address(token1),
            address(token2),
            1 ether
        );
        // 1 → 2 → 1.2
        assertEq(result, 1.2 ether);
    }

    function test_EstimateDualDexTrade_RouterReverts_ReturnsZero() public {
        RevertingRouter bad = new RevertingRouter();
        uint256 result = arb.estimateDualDexTrade(
            address(bad),
            address(router),
            address(token1),
            address(token2),
            1 ether
        );
        assertEq(result, 0);
    }

    // ── IsRegisteredRouter ──────────────────────────────────────────────────

    function test_IsRegisteredRouter_FalseInitially() public view {
        assertFalse(arb.isRegisteredRouter(address(router)));
    }

    function test_IsRegisteredRouter_TrueAfterAdding() public {
        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);
        assertTrue(arb.isRegisteredRouter(address(router)));
    }

    // ── getRouters ──────────────────────────────────────────────────

    function test_GetRouters_ReturnsEmptyInitially() public view {
        assertEq(arb.getRouters().length, 0);
    }

    function test_GetRouters_ReturnsRegisteredRouters() public {
        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(routerHalf);
        arb.addRouters(r);

        address[] memory result = arb.getRouters();
        assertEq(result.length, 2);
        assertEq(result[0], address(router));
        assertEq(result[1], address(routerHalf));
    }

    function test_GetRouters_ReflectsAppendedRouters() public {
        address[] memory r1 = new address[](1);
        r1[0] = address(router);
        arb.addRouters(r1);

        address[] memory r2 = new address[](1);
        r2[0] = address(routerHalf);
        arb.addRouters(r2);

        address[] memory result = arb.getRouters();
        assertEq(result.length, 2);
        assertEq(result[0], address(router));
        assertEq(result[1], address(routerHalf));
    }

    // ── dualDexTrade ─────────────────────────────────────────────────────────

    function _fundDual(uint256 amount) internal {
        token1.mint(address(arb), amount);
        token2.mint(address(router), amount * 2); // router pays out token2
        token1.mint(address(router06), (amount * 2 * 6) / 10);
    }

    function test_DualDexTrade_Profitable() public {
        uint256 amount = 10 ether;
        token1.mint(address(arb), amount);

        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(router06);
        arb.addRouters(r);

        token2.mint(address(router), amount * 2);
        token1.mint(address(router06), (amount * 2 * 6) / 10);

        uint256 before = token1.balanceOf(address(arb));
        arb.dualDexTrade(
            address(router),
            address(router06),
            address(token1),
            address(token2),
            amount
        );
        assertGt(token1.balanceOf(address(arb)), before);
    }

    function testRevert_DualDexTrade_RevertsIfUnprofitable() public {
        uint256 amount = 10 ether;
        token1.mint(address(arb), amount);

        MockRouter loser = new MockRouter(4, 10); // net 0.8x
        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(loser);
        arb.addRouters(r);

        token2.mint(address(router), amount * 2);
        token1.mint(address(loser), (amount * 2 * 4) / 10);

        vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
        arb.dualDexTrade(
            address(router),
            address(loser),
            address(token1),
            address(token2),
            amount
        );
    }

    function testRevert_DualDexTrade_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.dualDexTrade(
            address(router),
            address(routerHalf),
            address(token1),
            address(token2),
            1 ether
        );
    }

    function test_DualDexTrade_OnlyDeltaOfToken2IsTraded() public {
        uint256 amount = 10 ether;
        uint256 preExistingToken2 = 5 ether;
        token1.mint(address(arb), amount); // arb starts with 10 token1
        // Pre-existing token2 in arb — should NOT be included in leg-2
        token2.mint(address(arb), preExistingToken2); // arb starts with 5 token2

        // Snapshot balances before
        uint256 token1Before = token1.balanceOf(address(arb));
        uint256 token2Before = token2.balanceOf(address(arb));
        assertEq(token1Before, amount, "Should start with 10 token1");
        assertEq(
            token2Before,
            preExistingToken2,
            "Should start with 5 pre-existing token2"
        );

        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(router06);
        arb.addRouters(r);

        token2.mint(address(router), amount * 2); // router can pay out 20 token2
        token1.mint(address(router06), (amount * 2 * 6) / 10); // router06 can pay out 12 token1

        arb.dualDexTrade(
            address(router),
            address(router06),
            address(token1),
            address(token2),
            amount
        );

        // Snapshot balances after
        uint256 token1After = token1.balanceOf(address(arb));
        uint256 token2After = token2.balanceOf(address(arb));

        // token1 should have increased — profitable trade
        assertGt(
            token1After,
            token1Before,
            "Should end with more token1 than started"
        );

        // pre-existing token2 should be completely untouched
        assertEq(
            token2After,
            preExistingToken2,
            "Pre-existing token2 should be untouched"
        );
    }

    // ── estimateTriDexTrade ───────────────────────────────────────────────────────

    function test_EstimateTriDexTrade_Profitable() public view {
        // 2x → 2x → 2x = 8x, clearly profitable
        uint256 result = arb.estimateTriDexTrade(
            address(router),
            address(router),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            1 ether
        );
        assertEq(result, 8 ether);
    }

    function test_EstimateTriDexTrade_Unprofitable() public view {
        // 0.5x → 0.5x → 0.5x = 0.125x, clearly unprofitable
        uint256 result = arb.estimateTriDexTrade(
            address(routerHalf),
            address(routerHalf),
            address(routerHalf),
            address(token1),
            address(token2),
            address(token3),
            1 ether
        );
        assertLt(result, 1 ether);
    }

    function test_EstimateTriDexTrade_MixedRouters() public view {
        // 2x → 0.5x → 2x = 2x net, still profitable
        uint256 result = arb.estimateTriDexTrade(
            address(router),
            address(routerHalf),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            1 ether
        );
        assertEq(result, 2 ether);
    }

    function test_EstimateTriDexTrade_RouterReverts_ReturnsZero() public {
        RevertingRouter bad = new RevertingRouter();
        uint256 result = arb.estimateTriDexTrade(
            address(bad),
            address(router),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            1 ether
        );
        assertEq(result, 0);
    }

    function testRevert_EstimateTriDexTrade_ZeroAmount() public {
        vm.expectRevert(UniswapV2Arb.UniswapV2Arb_ZeroInputAmount.selector);
        arb.estimateTriDexTrade(
            address(router),
            address(router),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            0
        );
    }

    // ── triDexTrade ───────────────────────────────────────────────────────────────

    function _fundTriTrade(uint256 amount) internal {
        // router1: token1 → token2 at 2x
        token1.mint(address(arb), amount);
        token2.mint(address(router), amount * 2);

        // router2: token2 → token3 at 2x
        MockRouter router2x = new MockRouter(2, 1);
        token3.mint(address(router2x), amount * 4);

        // router3: token3 → token1 at 2x
        MockRouter router3x = new MockRouter(2, 1);
        token1.mint(address(router3x), amount * 8);
    }

    function test_TriDexTrade_Profitable() public {
        uint256 amount = 1 ether;
        token1.mint(address(arb), amount);

        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        // Use same 2x router for all hops: 1 → 2 → 4 → 8
        token2.mint(address(router), amount * 2);
        token3.mint(address(router), amount * 4);
        token1.mint(address(router), amount * 8);

        uint256 before = token1.balanceOf(address(arb));
        arb.triDexTrade(
            address(router),
            address(router),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            amount
        );
        assertGt(token1.balanceOf(address(arb)), before);
    }

    function test_TriDexTrade_Profitable_DifferentRouters() public {
        uint256 amount = 1 ether;
        token1.mint(address(arb), amount);

        MockRouter router2 = new MockRouter(2, 1);
        MockRouter router3 = new MockRouter(2, 1);

        address[] memory r = new address[](3);
        r[0] = address(router);
        r[1] = address(router2);
        r[2] = address(router3);
        arb.addRouters(r);

        token2.mint(address(router), amount * 2); // router1: 2x
        token3.mint(address(router2), amount * 4); // router2: 2x
        token1.mint(address(router3), amount * 8); // router3: 2x

        uint256 before = token1.balanceOf(address(arb));
        arb.triDexTrade(
            address(router),
            address(router2),
            address(router3),
            address(token1),
            address(token2),
            address(token3),
            amount
        );
        assertGt(token1.balanceOf(address(arb)), before);
    }

    function testRevert_TriDexTrade_RevertsIfUnprofitable() public {
        uint256 amount = 1 ether;
        token1.mint(address(arb), amount);

        address[] memory r = new address[](1);
        r[0] = address(routerHalf);
        arb.addRouters(r);

        // 0.5x each hop: 1 → 0.5 → 0.25 → 0.125
        token2.mint(address(routerHalf), amount);
        token3.mint(address(routerHalf), amount);
        token1.mint(address(routerHalf), amount);

        vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
        arb.triDexTrade(
            address(routerHalf),
            address(routerHalf),
            address(routerHalf),
            address(token1),
            address(token2),
            address(token3),
            amount
        );
    }

    function testRevert_TriDexTrade_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.triDexTrade(
            address(router),
            address(router),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            1 ether
        );
    }

    function test_TriDexTrade_OnlyDeltasAreTraded() public {
        uint256 amount = 1 ether;
        token1.mint(address(arb), amount);

        // Pre-existing intermediate balances
        token2.mint(address(arb), 50 ether);
        token3.mint(address(arb), 50 ether);

        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        // Router only seeded for leg outputs, not pre-existing balances
        token2.mint(address(router), amount * 2);
        token3.mint(address(router), amount * 4);
        token1.mint(address(router), amount * 8);

        arb.triDexTrade(
            address(router),
            address(router),
            address(router),
            address(token1),
            address(token2),
            address(token3),
            amount
        );
    }

    // ── router validation in swap ─────────────────────────────────────────────────

    function testRevert_DualDexTrade_RevertsIfRouter1NotRegistered() public {
        // Register only router2, not router
        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        token1.mint(address(arb), 1 ether);
        MockRouter unregistered = new MockRouter(2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterNotRegistered.selector,
                address(unregistered)
            )
        );
        arb.dualDexTrade(
            address(unregistered),
            address(router),
            address(token1),
            address(token2),
            1 ether
        );
    }

    function testRevert_DualDexTrade_RevertsIfRouter2NotRegistered() public {
        address[] memory r = new address[](1);
        r[0] = address(router);
        arb.addRouters(r);

        token1.mint(address(arb), 1 ether);
        token2.mint(address(router), 2 ether);
        MockRouter unregistered = new MockRouter(2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterNotRegistered.selector,
                address(unregistered)
            )
        );
        arb.dualDexTrade(
            address(router),
            address(unregistered),
            address(token1),
            address(token2),
            1 ether
        );
    }

    function testRevert_TriDexTrade_RevertsIfRouterNotRegistered() public {
        address[] memory r = new address[](2);
        r[0] = address(router);
        r[1] = address(routerHalf);
        arb.addRouters(r);

        token1.mint(address(arb), 1 ether);
        MockRouter unregistered = new MockRouter(2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterNotRegistered.selector,
                address(unregistered)
            )
        );
        arb.triDexTrade(
            address(unregistered),
            address(router),
            address(routerHalf),
            address(token1),
            address(token2),
            address(token3),
            1 ether
        );
    }

    function testRevert_TradePath_RevertsIfRouterNotRegistered() public {
        token1.mint(address(arb), 1 ether);
        MockRouter unregistered = new MockRouter(2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV2Arb.UniswapV2Arb_RouterNotRegistered.selector,
                address(unregistered)
            )
        );
        arb.tradePath(
            address(unregistered),
            address(token1),
            address(token2),
            address(token3),
            address(token4),
            1 ether
        );
    }

    // ── getBalance ────────────────────────────────────────────────────────────

    function test_GetBalance_ReturnsCorrectBalance() public {
        token1.mint(address(arb), 42 ether);
        assertEq(arb.getBalance(address(token1)), 42 ether);
    }

    function test_GetBalance_ZeroWhenEmpty() public view {
        assertEq(arb.getBalance(address(token1)), 0);
    }

    // ── recoverEth ────────────────────────────────────────────────────────────

    function test_RecoverEth_SendsEthToOwner() public {
        vm.deal(address(arb), 1 ether);
        uint256 before = owner.balance;
        arb.recoverEth();
        assertEq(owner.balance - before, 1 ether);
        assertEq(address(arb).balance, 0);
    }

    function testRevert_RecoverEth_OnlyOwner() public {
        vm.deal(address(arb), 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.recoverEth();
    }

    function test_RecoverEth_NoEthIsNoop() public {
        uint256 before = owner.balance;
        arb.recoverEth();
        assertEq(owner.balance, before);
    }

    // ── recoverTokens ─────────────────────────────────────────────────────────

    function test_RecoverTokens_TransfersAllToOwner() public {
        token1.mint(address(arb), 100 ether);
        uint256 before = token1.balanceOf(owner);
        arb.recoverTokens(address(token1));
        assertEq(token1.balanceOf(owner) - before, 100 ether);
        assertEq(token1.balanceOf(address(arb)), 0);
    }

    function testRevert_RecoverTokens_OnlyOwner() public {
        token1.mint(address(arb), 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        arb.recoverTokens(address(token1));
    }

    function test_RecoverTokens_ZeroBalance_IsNoop() public {
        arb.recoverTokens(address(token1));
        assertEq(token1.balanceOf(owner), 0);
    }
}
