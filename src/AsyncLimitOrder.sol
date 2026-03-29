// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {OrderBook} from "./OrderBook.sol";
import {ClaimManager} from "./ClaimManager.sol";

/// @title AsyncLimitOrder
/// @notice Uniswap v4 hook implementing trustless, keeper-free on-chain limit orders
///         via single-tick concentrated liquidity positions.
contract AsyncLimitOrder is BaseHook, OrderBook, ClaimManager, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    uint160 private constant Q96 = 2 ** 96;
    enum Action { PLACE, CANCEL }

    error OrderAlreadyFilled();

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // ===== Hook Permissions =====
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ===== Hook Callbacks =====

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal override returns (bytes4)
    {
        lastTick[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal pure override returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 last = lastTick[key.toId()];
        int24 spacing = key.tickSpacing;

        if (currentTick > last) {
            for (int24 t = last; t < currentTick; t += spacing) {
                _fillTickOrders(key, t, true);
            }
        } else if (currentTick < last) {
            for (int24 t = last; t > currentTick; t -= spacing) {
                _fillTickOrders(key, t, false);
            }
        }

        lastTick[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // ===== External Functions =====

    function placeOrder(PoolKey calldata key, uint256 amountIn, int24 targetTick, bool zeroForOne)
        external returns (bytes32)
    {
        if (targetTick % key.tickSpacing != 0) revert TickNotAligned();

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(inputCurrency)).transferFrom(msg.sender, address(this), amountIn);

        bytes memory result = poolManager.unlock(
            abi.encode(Action.PLACE, abi.encode(key, amountIn, targetTick, zeroForOne, msg.sender))
        );
        return abi.decode(result, (bytes32));
    }

    function cancelOrder(bytes32 orderId, PoolKey calldata key) external {
        Order storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (order.filled) revert OrderAlreadyFilled();

        poolManager.unlock(abi.encode(Action.CANCEL, abi.encode(orderId, key)));
        emit OrderCancelled(orderId);
    }

    function claim(bytes32 orderId, PoolKey calldata key) external {
        Order storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (!order.filled) revert OrderNotFilled();
        if (order.claimed) revert AlreadyClaimed();

        order.claimed = true;
        uint256 amt0 = claimable0[orderId];
        uint256 amt1 = claimable1[orderId];
        delete claimable0[orderId];
        delete claimable1[orderId];

        if (amt0 > 0) key.currency0.transfer(msg.sender, amt0);
        if (amt1 > 0) key.currency1.transfer(msg.sender, amt1);

        emit OrderClaimed(orderId, amt0, amt1);
    }

    // ===== Unlock Callback =====

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (Action action, bytes memory params) = abi.decode(data, (Action, bytes));

        if (action == Action.PLACE) {
            return _handlePlace(params);
        } else {
            _handleCancel(params);
            return "";
        }
    }

    function _handlePlace(bytes memory params) internal returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, int24 targetTick, bool zeroForOne, address owner)
            = abi.decode(params, (PoolKey, uint256, int24, bool, address));

        int24 tickUpper = targetTick + key.tickSpacing;
        uint128 liquidity = _computeLiquidity(amountIn, targetTick, tickUpper, zeroForOne);

        // Pre-compute orderId for use as salt
        uint256 nonce = nonces[owner];
        bytes32 orderId = _computeOrderId(owner, key.toId(), targetTick, zeroForOne, nonce);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: targetTick,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: orderId
            }),
            ""
        );

        // Settle: send tokens we owe to PM
        if (delta.amount0() < 0) _settle(key.currency0, uint128(-delta.amount0()));
        if (delta.amount1() < 0) _settle(key.currency1, uint128(-delta.amount1()));
        if (delta.amount0() > 0) _take(key.currency0, uint128(delta.amount0()));
        if (delta.amount1() > 0) _take(key.currency1, uint128(delta.amount1()));

        _storeOrder(owner, key.toId(), targetTick, tickUpper, zeroForOne, liquidity);
        return abi.encode(orderId);
    }

    function _handleCancel(bytes memory params) internal {
        (bytes32 orderId, PoolKey memory key) = abi.decode(params, (bytes32, PoolKey));
        Order storage order = orders[orderId];

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: order.tickLower,
                tickUpper: order.tickUpper,
                liquidityDelta: -int256(uint256(order.liquidity)),
                salt: orderId
            }),
            ""
        );

        if (delta.amount0() > 0) _take(key.currency0, uint128(delta.amount0()));
        if (delta.amount1() > 0) _take(key.currency1, uint128(delta.amount1()));
        if (delta.amount0() < 0) _settle(key.currency0, uint128(-delta.amount0()));
        if (delta.amount1() < 0) _settle(key.currency1, uint128(-delta.amount1()));

        // Transfer recovered tokens to owner
        if (delta.amount0() > 0) key.currency0.transfer(order.owner, uint256(int256(delta.amount0())));
        if (delta.amount1() > 0) key.currency1.transfer(order.owner, uint256(int256(delta.amount1())));

        _removeFromTickIndex(orderId, order.poolId, order.tickLower, order.zeroForOne);
        delete orders[orderId];
    }

    // ===== Internal Helpers =====

    function _fillTickOrders(PoolKey calldata key, int24 tick, bool zeroForOne) internal {
        bytes32 tKey = _tickKey(key.toId(), tick, zeroForOne);
        bytes32[] storage ids = tickOrders[tKey];
        uint256 len = ids.length;
        if (len == 0) return;

        uint256 fillCount = len > MAX_ORDERS_PER_TICK ? MAX_ORDERS_PER_TICK : len;
        for (uint256 i; i < fillCount; i++) {
            Order storage ord = orders[ids[i]];

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: ord.tickLower,
                    tickUpper: ord.tickUpper,
                    liquidityDelta: -int256(uint256(ord.liquidity)),
                    salt: ids[i]
                }),
                ""
            );

            if (delta.amount0() > 0) _take(key.currency0, uint128(delta.amount0()));
            if (delta.amount1() > 0) _take(key.currency1, uint128(delta.amount1()));
            if (delta.amount0() < 0) _settle(key.currency0, uint128(-delta.amount0()));
            if (delta.amount1() < 0) _settle(key.currency1, uint128(-delta.amount1()));

            uint256 amt0 = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
            uint256 amt1 = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
            _recordFill(ids[i], amt0, amt1);
            ord.filled = true;
        }

        // Clean up tick index
        if (fillCount == len) {
            delete tickOrders[tKey];
        } else {
            for (uint256 i; i < len - fillCount; i++) {
                ids[i] = ids[fillCount + i];
            }
            for (uint256 i; i < fillCount; i++) ids.pop();
        }
    }

    function _computeLiquidity(uint256 amountIn, int24 tickLower, int24 tickUpper, bool zeroForOne)
        internal pure returns (uint128)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 diff = uint256(sqrtUpper) - uint256(sqrtLower);

        if (zeroForOne) {
            // L = amount0 * sqrtLower * sqrtUpper / (Q96 * diff)
            uint256 intermediate = amountIn.mulDivDown(uint256(sqrtLower), diff);
            return uint128(intermediate.mulDivDown(uint256(sqrtUpper), Q96));
        } else {
            // L = amount1 * Q96 / diff
            return uint128(amountIn.mulDivDown(Q96, diff));
        }
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
}
