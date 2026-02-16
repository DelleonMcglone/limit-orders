# Take-Profit Limit Orders Hook

A Uniswap V4 hook that implements on-chain take-profit limit orders. Users can place orders to automatically sell tokens when the price reaches a target level, with execution happening atomically inside `afterSwap`.

## How It Works

### Placing Orders

Users place limit orders by specifying a pool, a tick (price level), a direction (`zeroForOne` or `oneForZero`), and an input amount. The hook holds the input tokens and mints ERC-1155 claim tokens representing the user's position.

### Order Execution

When a swap occurs in the pool, the `afterSwap` hook checks if the tick has shifted past any pending order levels:

- **Tick increases** (Token 0 price rises) — executes `zeroForOne` sell orders within the new tick range
- **Tick decreases** (Token 1 price rises) — executes `oneForZero` sell orders within the new tick range

Each order execution itself shifts the tick further, so the hook re-evaluates the tick range after every fill. This prevents orders from being incorrectly executed when prior fills have already moved the price back.

### Redeeming

After an order is filled, holders of the corresponding ERC-1155 claim tokens can redeem their proportional share of the output tokens.

### Cancelling

Users can cancel unfilled orders at any time to reclaim their input tokens.

## Key Design Decisions

- **Re-entrancy guard**: `afterSwap` short-circuits when `sender` is the hook itself, preventing recursive execution loops
- **Tick-aware fulfillment**: Orders are filled one at a time with tick re-evaluation between each, so a fill that moves the price back won't incorrectly trigger further orders
- **Aggregated positions**: Multiple users placing the same order (same pool, tick, direction) are batched into a single swap for gas efficiency

## Project Structure

```
src/
  TakeProfitsHook.sol   # The hook contract
test/
  TakeProfitsHook.t.sol # Test suite
```

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

## Dependencies

- [Uniswap V4 Core](https://github.com/Uniswap/v4-core)
- [Uniswap V4 Periphery](https://github.com/Uniswap/v4-periphery)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) (ERC-1155)
- [Solmate](https://github.com/transmissions11/solmate) (FixedPointMathLib)
