// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Currency} from "v4-core/types/Currency.sol";

/// @title ClaimManager
/// @notice Claim accounting and withdrawal logic for filled limit orders
abstract contract ClaimManager {
    // ===== State =====
    /// @notice Claimable token0 amount per filled order
    mapping(bytes32 orderId => uint256 amount0) public claimable0;

    /// @notice Claimable token1 amount per filled order
    mapping(bytes32 orderId => uint256 amount1) public claimable1;

    // ===== Events =====
    event OrderFilled(bytes32 indexed orderId);
    event OrderClaimed(bytes32 indexed orderId, uint256 amount0, uint256 amount1);

    // ===== Errors =====
    error NotOrderOwner();
    error OrderNotFilled();
    error AlreadyClaimed();

    // ===== Internal Functions =====

    /// @notice Record a fill for an order after liquidity removal
    function _recordFill(bytes32 orderId, uint256 amount0, uint256 amount1) internal {
        claimable0[orderId] += amount0;
        claimable1[orderId] += amount1;
        emit OrderFilled(orderId);
    }
}
