// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AsyncLimitOrder} from "../src/AsyncLimitOrder.sol";

contract AsyncLimitOrderTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    Currency token0;
    Currency token1;

    AsyncLimitOrder hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy hook at address with correct flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo(
            "AsyncLimitOrder.sol",
            abi.encode(manager),
            hookAddress
        );
        hook = AsyncLimitOrder(hookAddress);

        // Approve hook to spend tokens
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize pool: 1:1 price, 60-tick spacing, 3000 bps fee
        (key, ) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Add initial liquidity at multiple ranges
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ===== placeOrder Tests =====

    function test_placeOrder() public {
        uint256 amount = 1 ether;
        int24 targetTick = 60; // Above current tick (0), sell token0
        bool zeroForOne = true;

        uint256 balBefore = token0.balanceOfSelf();
        bytes32 orderId = hook.placeOrder(key, amount, targetTick, zeroForOne);
        uint256 balAfter = token0.balanceOfSelf();

        // Tokens transferred from user
        assertEq(balBefore - balAfter, amount);

        // Order stored correctly
        (address owner,,,,, uint128 liquidity, bool filled, bool claimed)
            = hook.orders(orderId);
        assertEq(owner, address(this));
        assertTrue(liquidity > 0);
        assertFalse(filled);
        assertFalse(claimed);
    }

    function test_placeOrder_revertsOnMisalignedTick() public {
        vm.expectRevert();
        hook.placeOrder(key, 1 ether, 55, true); // 55 is not a multiple of 60
    }

    // ===== afterSwap Fill Tests =====

    function test_fillOrder_zeroForOne() public {
        // Place order to sell token0 at tick 60
        uint256 amount = 0.1 ether;
        bytes32 orderId = hook.placeOrder(key, amount, 60, true);

        // Swap to move tick up past 60
        PoolSwapTest.TestSettings memory settings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );

        // Order should be filled
        (,,,,,, bool filled,) = hook.orders(orderId);
        assertTrue(filled);

        // Should have claimable token1
        uint256 claim1 = hook.claimable1(orderId);
        assertTrue(claim1 > 0);
    }

    function test_fillOrder_oneForZero() public {
        // Place order to sell token1 at tick -60 (below current tick)
        uint256 amount = 0.1 ether;
        bytes32 orderId = hook.placeOrder(key, amount, -60, false);

        // Swap to move tick down past -60
        PoolSwapTest.TestSettings memory settings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Order should be filled
        (,,,,,, bool filled,) = hook.orders(orderId);
        assertTrue(filled);

        // Should have claimable token0
        uint256 claim0 = hook.claimable0(orderId);
        assertTrue(claim0 > 0);
    }

    // ===== claim Tests =====

    function test_claim() public {
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);

        // Fill the order
        _swapUp(1 ether);

        // Claim
        uint256 balBefore = token1.balanceOf(address(this));
        hook.claim(orderId, key);
        uint256 balAfter = token1.balanceOf(address(this));

        assertTrue(balAfter > balBefore);

        // Verify claimed flag
        (,,,,,,, bool claimed) = hook.orders(orderId);
        assertTrue(claimed);
    }

    function test_doubleClaim_reverts() public {
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);
        _swapUp(1 ether);

        hook.claim(orderId, key);

        vm.expectRevert();
        hook.claim(orderId, key);
    }

    function test_claim_revertsIfNotFilled() public {
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);

        vm.expectRevert();
        hook.claim(orderId, key);
    }

    function test_claim_revertsIfNotOwner() public {
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);
        _swapUp(1 ether);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.claim(orderId, key);
    }

    // ===== cancelOrder Tests =====

    function test_cancelOrder() public {
        uint256 balBefore = token0.balanceOfSelf();
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);
        uint256 balAfterPlace = token0.balanceOfSelf();
        assertEq(balBefore - balAfterPlace, 0.1 ether);

        hook.cancelOrder(orderId, key);

        uint256 balAfterCancel = token0.balanceOfSelf();
        // Should get tokens back (may have small rounding difference)
        assertTrue(balAfterCancel > balAfterPlace);

        // Order should be deleted
        (address owner,,,,,,,) = hook.orders(orderId);
        assertEq(owner, address(0));
    }

    function test_cancelOrder_revertsIfFilled() public {
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);
        _swapUp(1 ether);

        vm.expectRevert();
        hook.cancelOrder(orderId, key);
    }

    function test_cancelOrder_revertsIfNotOwner() public {
        bytes32 orderId = hook.placeOrder(key, 0.1 ether, 60, true);

        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.cancelOrder(orderId, key);
    }

    // ===== Multi-tick crossing =====

    function test_multiTickCrossing() public {
        // Place orders at tick 0 and tick 60
        bytes32 orderId0 = hook.placeOrder(key, 0.01 ether, 0, true);
        bytes32 orderId60 = hook.placeOrder(key, 0.01 ether, 60, true);

        // Swap enough to cross both ticks
        _swapUp(0.5 ether);

        // Check which orders got filled
        (,,,,,, bool filled0,) = hook.orders(orderId0);
        (,,,,,, bool filled60,) = hook.orders(orderId60);

        // At least the first order should be filled
        assertTrue(filled0);
        // The second may or may not be filled depending on how far tick moved
    }

    // ===== Helper =====

    function _swapUp(uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );
    }

    function _swapDown(uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
    }
}
