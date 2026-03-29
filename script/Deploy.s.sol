// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {AsyncLimitOrder} from "../src/AsyncLimitOrder.sol";

/// @title Deploy script for AsyncLimitOrder hook on Base Sepolia
/// @notice Mines a CREATE2 salt so the deployed address encodes the required hook flags.
contract Deploy is Script {
    // Base Sepolia PoolManager
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    // Required hook flags encoded in the address
    uint160 constant TARGET_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_SWAP_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        bytes memory creationCode = abi.encodePacked(
            type(AsyncLimitOrder).creationCode,
            abi.encode(IPoolManager(POOL_MANAGER))
        );

        // Mine salt for CREATE2 address with correct flag bits
        bytes32 salt = _mineSalt(msg.sender, creationCode, TARGET_FLAGS);
        address predicted = computeCreate2(msg.sender, salt, creationCode);
        console.log("Deployer:", msg.sender);
        console.log("Salt:", uint256(salt));
        console.log("Predicted address:", predicted);

        vm.startBroadcast();
        AsyncLimitOrder hook = new AsyncLimitOrder{salt: salt}(
            IPoolManager(POOL_MANAGER)
        );
        vm.stopBroadcast();

        require(address(hook) == predicted, "Address mismatch");
        console.log("Deployed AsyncLimitOrder at:", address(hook));
    }

    function _mineSalt(address deployer, bytes memory creationCode, uint160 flags)
        internal pure returns (bytes32)
    {
        for (uint256 salt; salt < 10_000; salt++) {
            address addr = computeCreate2(deployer, bytes32(salt), creationCode);
            if (uint160(addr) & TARGET_FLAGS == flags) {
                return bytes32(salt);
            }
        }
        revert("Salt not found within 10000 iterations");
    }

    function computeCreate2(address deployer, bytes32 salt, bytes memory creationCode)
        internal pure returns (address)
    {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode))
        ))));
    }
}
