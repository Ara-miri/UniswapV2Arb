// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UniswapV2Arb} from "../src/UniswapV2Arb.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mock ERC20 ───────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─── Mock Uniswap V2 Router ───────────────────────────────────────────────────

contract MockRouter {
    uint256 public rateNumerator;
    uint256 public rateDenominator;

    constructor(uint256 _num, uint256 _den) {
        rateNumerator = _num;
        rateDenominator = _den;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = (amountIn * rateNumerator) / rateDenominator;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 amountOut = (amountIn * rateNumerator) / rateDenominator;

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }
}

// ─── Reverting Router (for getAmountOutMin try/catch test) ───────────────────

contract RevertingRouter {
    function getAmountsOut(
        uint256,
        address[] calldata
    ) external pure returns (uint256[] memory) {
        revert("pool does not exist");
    }
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

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

    function test_AddPath_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
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

    function test_TradePath_RevertsIfUnprofitable() public {
        uint256 amount = 10 ether;
        baseAsset.mint(address(arb), amount);

        // Seed routerHalf with enough tokens (0.5x each hop — always a loss)
        token1.mint(address(routerHalf), amount);
        stable1.mint(address(routerHalf), amount);
        token2.mint(address(routerHalf), amount);
        baseAsset.mint(address(routerHalf), amount);

        vm.expectRevert("Trade Reverted, No Profit Made");
        arb.tradePath(
            address(routerHalf),
            address(baseAsset),
            address(token1),
            address(stable1),
            address(token2),
            amount
        );
    }

    function test_TradePath_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
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

    function test_AddRouters_OnlyOwner() public {
        address[] memory r = new address[](1);
        r[0] = address(router);
        vm.prank(alice);
        vm.expectRevert();
        arb.addRouters(r);
    }

    function test_AddRouters_Appends() public {
        address[] memory r1 = new address[](1);
        r1[0] = address(router);
        arb.addRouters(r1);

        address[] memory r2 = new address[](1);
        r2[0] = address(routerHalf);
        arb.addRouters(r2);

        assertEq(arb.routers(0), address(router));
        assertEq(arb.routers(1), address(routerHalf));
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

    function test_EstimateDualDexTrade_Profitable() public {
        // router (2x) then routerHalf (0.5x) on way back — but we use router both ways: net 4x
        MockRouter router06 = new MockRouter(6, 10);
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

    // ── dualDexTrade ─────────────────────────────────────────────────────────

    function _fundDual(uint256 amount) internal {
        token1.mint(address(arb), amount);
        token2.mint(address(router), amount * 2); // router pays out token2
        MockRouter router06 = new MockRouter(6, 10);
        token1.mint(address(router06), (amount * 2 * 6) / 10);
        // return router06 so caller can use it
    }

    function test_DualDexTrade_Profitable() public {
        uint256 amount = 10 ether;
        token1.mint(address(arb), amount);

        MockRouter router06 = new MockRouter(6, 10);
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

    function test_DualDexTrade_RevertsIfUnprofitable() public {
        uint256 amount = 10 ether;
        token1.mint(address(arb), amount);

        MockRouter loser = new MockRouter(4, 10); // net 0.8x
        token2.mint(address(router), amount * 2);
        token1.mint(address(loser), (amount * 2 * 4) / 10);

        vm.expectRevert("Trade Reverted, No Profit Made");
        arb.dualDexTrade(
            address(router),
            address(loser),
            address(token1),
            address(token2),
            amount
        );
    }

    function test_DualDexTrade_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
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
        token1.mint(address(arb), amount);

        MockRouter router06 = new MockRouter(6, 10);
        token2.mint(address(router), amount * 2);
        token1.mint(address(router06), (amount * 2 * 6) / 10);

        // Pre-existing token2 in arb — should NOT be included in leg-2
        token2.mint(address(arb), 5 ether);

        arb.dualDexTrade(
            address(router),
            address(router06),
            address(token1),
            address(token2),
            amount
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

    function test_RecoverEth_OnlyOwner() public {
        vm.deal(address(arb), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
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

    function test_RecoverTokens_OnlyOwner() public {
        token1.mint(address(arb), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        arb.recoverTokens(address(token1));
    }

    function test_RecoverTokens_ZeroBalance_IsNoop() public {
        arb.recoverTokens(address(token1));
        assertEq(token1.balanceOf(owner), 0);
    }
}
