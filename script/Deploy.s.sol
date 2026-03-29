// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AsyncLimitOrder} from "../src/AsyncLimitOrder.sol";

/// @title Deploy
/// @notice Deploys AsyncLimitOrder via CREATE2 and initializes the WETH/USDC pool on Base Sepolia.
contract Deploy is Script {
    // ─── Base Sepolia Constants ──────────────────────────────────────────────
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant USDC             = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // Native ETH represented as address(0) in Uniswap v4
    address constant NATIVE_ETH       = address(0);

    // Required hook flags: afterInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG      |
        Hooks.AFTER_SWAP_FLAG       |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        // Mine salt before broadcast (pure computation — no gas)
        bytes memory creationCode = abi.encodePacked(
            type(AsyncLimitOrder).creationCode,
            abi.encode(address(POOL_MANAGER))
        );
        bytes32 salt = _mineSalt(CREATE2_FACTORY, creationCode, HOOK_FLAGS); // inherited from forge-std/Base.sol
        console.log("Salt mined:", uint256(salt));

        vm.startBroadcast(deployerPk);

        // Deploy AsyncLimitOrder via CREATE2
        AsyncLimitOrder hook = new AsyncLimitOrder{salt: salt}(POOL_MANAGER);
        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS,
            "Hook address flag mismatch"
        );
        console.log("AsyncLimitOrder deployed at:", address(hook));

        // Initialize WETH/USDC pool (native ETH = address(0), fee 3000, tickSpacing 60)
        (Currency c0, Currency c1) = _sortCurrencies(NATIVE_ETH, USDC);
        PoolKey memory poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        POOL_MANAGER.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        console.log("WETH/USDC pool initialized");

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Deployment Summary (Base Sepolia)");
        console.log("========================================");
        console.log("AsyncLimitOrder:", address(hook));
        console.log("PoolManager:    ", address(POOL_MANAGER));
        console.log("Deployer:       ", deployer);
    }

    /// @dev Mine a CREATE2 salt whose resulting address lower bits match the required hook flags.
    function _mineSalt(address factory, bytes memory creationCode, uint160 flags)
        internal pure returns (bytes32)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i; i < 100_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(uint160(uint256(
                keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash))
            )));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) {
                return salt;
            }
        }
        revert("Salt not found within 100k iterations");
    }

    function _sortCurrencies(address a, address b) internal pure returns (Currency, Currency) {
        if (a < b) return (Currency.wrap(a), Currency.wrap(b));
        return (Currency.wrap(b), Currency.wrap(a));
    }
}
