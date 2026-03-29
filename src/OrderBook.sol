// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title OrderBook
/// @notice Order storage, tick index, and ID helpers for the Async Limit Order hook
abstract contract OrderBook {
    // ===== Types =====
    struct Order {
        address owner;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        bool zeroForOne;
        uint128 liquidity;
        bool filled;
        bool claimed;
    }

    // ===== Constants =====
    uint256 public constant MAX_ORDERS_PER_TICK = 50;
    uint256 public constant ORDER_EXPIRY = 30 days;

    // ===== State =====
    /// @notice orderId => Order
    mapping(bytes32 => Order) public orders;

    /// @notice tickKey => orderId[] — reverse index for afterSwap lookups
    /// tickKey = keccak256(abi.encode(poolId, tickLower, zeroForOne))
    mapping(bytes32 => bytes32[]) internal tickOrders;

    /// @notice Last known tick per pool (set in afterInitialize + afterSwap)
    mapping(PoolId => int24) public lastTick;

    /// @notice Per-user nonce for deterministic orderId generation
    mapping(address => uint256) public nonces;

    // ===== Events =====
    event OrderPlaced(bytes32 indexed orderId, address indexed owner, int24 tickLower, bool zeroForOne, uint128 liquidity);
    event OrderCancelled(bytes32 indexed orderId);

    // ===== Errors =====
    error TickNotAligned();
    error TooManyOrdersAtTick();

    // ===== Internal Functions =====

    /// @notice Compute a deterministic order ID
    function _computeOrderId(
        address owner,
        PoolId poolId,
        int24 tickLower,
        bool zeroForOne,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, poolId, tickLower, zeroForOne, nonce));
    }

    /// @notice Compute the tick index key for reverse lookups
    function _tickKey(PoolId poolId, int24 tickLower, bool zeroForOne) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, tickLower, zeroForOne));
    }

    /// @notice Store an order and add it to the tick index
    function _storeOrder(
        address owner,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        bool zeroForOne,
        uint128 liquidity
    ) internal returns (bytes32 orderId) {
        uint256 nonce = nonces[owner]++;
        orderId = _computeOrderId(owner, poolId, tickLower, zeroForOne, nonce);

        orders[orderId] = Order({
            owner: owner,
            poolId: poolId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            zeroForOne: zeroForOne,
            liquidity: liquidity,
            filled: false,
            claimed: false
        });

        bytes32 tKey = _tickKey(poolId, tickLower, zeroForOne);
        if (tickOrders[tKey].length >= MAX_ORDERS_PER_TICK) revert TooManyOrdersAtTick();
        tickOrders[tKey].push(orderId);

        emit OrderPlaced(orderId, owner, tickLower, zeroForOne, liquidity);
    }

    /// @notice Remove an order from the tick index
    function _removeFromTickIndex(bytes32 orderId, PoolId poolId, int24 tickLower, bool zeroForOne) internal {
        bytes32 tKey = _tickKey(poolId, tickLower, zeroForOne);
        bytes32[] storage ids = tickOrders[tKey];
        uint256 len = ids.length;
        for (uint256 i; i < len; i++) {
            if (ids[i] == orderId) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
        }
    }

    /// @notice Get all order IDs at a given tick
    function getTickOrders(PoolId poolId, int24 tickLower, bool zeroForOne) external view returns (bytes32[] memory) {
        return tickOrders[_tickKey(poolId, tickLower, zeroForOne)];
    }
}
