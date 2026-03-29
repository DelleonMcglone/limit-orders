# AsyncLimitOrder

Uniswap v4 hook that implements trustless, keeper-free on-chain limit orders for ETH/USDC via single-tick concentrated liquidity. The AMM fills orders natively as price crosses the target tick — no off-chain bots or keepers required.

**Chain:** Base Sepolia (84532)
**Pool:** WETH/USDC · 0.3% fee · 60-tick spacing

## Architecture

```
src/
├── AsyncLimitOrder.sol    # Hook — afterInitialize, beforeSwap (returnDelta), afterSwap
├── OrderBook.sol          # Order struct, tick-indexed storage, orderId helpers
└── ClaimManager.sol       # Claimable balance accounting, fill recording

test/
└── AsyncLimitOrder.t.sol  # Integration tests (place, fill, claim, cancel, edge cases)

script/
└── Deploy.s.sol           # CREATE2 salt mining + deployment to Base Sepolia
```

## How It Works

1. **User** calls `placeOrder(poolKey, amountIn, targetTick, zeroForOne)` — tokens are transferred to the hook, which adds concentrated liquidity at `[targetTick, targetTick + tickSpacing]` via `poolManager.modifyLiquidity`
2. **Swap occurs** in the pool — the AMM's own x·y=k logic converts the single-sided position as price crosses the target tick
3. **`afterSwap`** detects which ticks were crossed, removes filled liquidity positions, and records claimable output in `ClaimManager`
4. **User** calls `claim(orderId, poolKey)` at any time to withdraw the converted output tokens
5. **Cancel path** — unfilled orders can be cancelled at any time via `cancelOrder(orderId, poolKey)`, which removes the liquidity position and returns input tokens

## Base Sepolia Contracts

| Contract | Address | Basescan |
|----------|---------|----------|
| PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | [Verified](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408#code) |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | [Verified](https://sepolia.basescan.org/address/0x036CbD53842c5426634e7929541eC2318f3dCF7e#code) |
| **AsyncLimitOrder** | pending deployment | — |

## Hook Flags

```solidity
Hooks.Permissions({
    afterInitialize:       true,   // record initial pool tick
    beforeSwap:            true,   // async swap primitive (returnDelta)
    afterSwap:             true,   // detect tick crossings, fill orders
    beforeSwapReturnDelta: true,   // custody input via async pattern
    // all others:         false
})
```

Address must encode `AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG` bits via CREATE2.

## API Reference

### AsyncLimitOrder

| Function | Access | Description |
|----------|--------|-------------|
| `placeOrder(PoolKey, amountIn, targetTick, zeroForOne) → bytes32` | Public | Place a limit order; returns `orderId` |
| `cancelOrder(orderId, PoolKey)` | Order owner | Cancel an unfilled order; returns input tokens |
| `claim(orderId, PoolKey)` | Order owner | Withdraw output tokens from a filled order |

### OrderBook

| Function | Access | Description |
|----------|--------|-------------|
| `orders(orderId) → Order` | Public | Read order state |
| `getTickOrders(poolId, tick, zeroForOne) → bytes32[]` | Public | List order IDs at a tick |
| `lastTick(poolId) → int24` | Public | Last known tick for a pool |

### Errors

| Error | When |
|-------|------|
| `TickNotAligned()` | `targetTick` is not a multiple of `tickSpacing` |
| `TooManyOrdersAtTick()` | Tick already has `MAX_ORDERS_PER_TICK` (50) orders |
| `NotOrderOwner()` | Caller is not the order owner |
| `OrderNotFilled()` | `claim` called on an unfilled order |
| `OrderAlreadyFilled()` | `cancelOrder` called on a filled order |
| `AlreadyClaimed()` | `claim` called on an already-claimed order |

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_ORDERS_PER_TICK` | `50` | Loop cap per tick in `afterSwap` — prevents DoS |
| `ORDER_EXPIRY` | `30 days` | Expiry window after which owner can force-cancel |

## Integration Guide

### Placing a limit order

```solidity
// Approve tokens first
IERC20(weth).approve(address(hook), amountIn);

// Place a sell-ETH order at tick 200700 (~$3,000)
bytes32 orderId = hook.placeOrder(
    poolKey,
    amountIn,      // WETH amount
    200700,        // targetTick (must be multiple of tickSpacing = 60)
    true           // zeroForOne: sell token0 (WETH) for token1 (USDC)
);
```

### Claiming a filled order

```solidity
// After price has crossed the target tick:
hook.claim(orderId, poolKey);
```

### Cancelling an unfilled order

```solidity
hook.cancelOrder(orderId, poolKey);
```

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test -vvv
```

### Coverage

```shell
forge coverage
```

### Deploy

```shell
export PRIVATE_KEY=<your_private_key>
export RPC_URL=https://sepolia.base.org

forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

### Verify on Basescan

```shell
forge verify-contract <HOOK_ADDR> src/AsyncLimitOrder.sol:AsyncLimitOrder \
  --chain base-sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408)
```

## Security

- `afterSwap` short-circuits when `sender == address(this)` — prevents re-entrant fill loops
- CEI enforced in all state-mutating functions — state written before any external calls
- `MAX_ORDERS_PER_TICK = 50` caps the `afterSwap` loop — prevents unbounded gas DoS
- `order.claimed` flag set atomically before token transfer — prevents double-spend
- `require(!order.filled)` guard on `cancelOrder` — prevents cancellation of filled orders
- All `poolManager.unlock` callbacks validate `msg.sender == address(poolManager)`
- Hook holds no permanent token balances — all tokens are in the PoolManager's custody as liquidity

## Known Limitations

- Orders beyond `MAX_ORDERS_PER_TICK` are not auto-filled by `afterSwap`. A `forceFill` escape hatch is planned for a future release.
- Single-tick liquidity positions carry basis-point rounding at extreme tick values — enforce a minimum order size at the UI layer.
- `zeroForOne = true` orders must be placed above the current tick; `zeroForOne = false` orders must be placed below. Validation is the caller's responsibility.

## Test Coverage

```
Ran 12 tests for test/AsyncLimitOrder.t.sol:AsyncLimitOrderTest

PASS  test_placeOrder
PASS  test_placeOrder_revertsOnMisalignedTick
PASS  test_fillOrder_zeroForOne
PASS  test_fillOrder_oneForZero
PASS  test_claim
PASS  test_doubleClaim_reverts
PASS  test_claim_revertsIfNotFilled
PASS  test_claim_revertsIfNotOwner
PASS  test_cancelOrder
PASS  test_cancelOrder_revertsIfFilled
PASS  test_cancelOrder_revertsIfNotOwner
PASS  test_multiTickCrossing

12 passed · 0 failed
```

## Dependencies

- [Uniswap v4 Core](https://github.com/Uniswap/v4-core)
- [Uniswap v4 Periphery](https://github.com/Uniswap/v4-periphery)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Solmate](https://github.com/transmissions11/solmate) (FixedPointMathLib)
- [Foundry](https://github.com/foundry-rs/foundry)

## License

MIT
