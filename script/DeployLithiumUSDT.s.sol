// SPDX-License-Identifier: LicenseRef-Lithium-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {LithiumUSDT} from "../src/testnet/LithiumUSDT.sol";

/// @notice Deploy the token and built-in faucet, without minting or changing any market.
/// @dev Use a Foundry keystore or hardware signer. No private-key environment variable.
contract DeployLithiumUSDT is Script {
    error WrongChain();
    error InvalidOwner();
    event Deployment(address indexed token, address indexed owner, uint256 chainId);

    function run() external returns (LithiumUSDT token) {
        if (block.chainid != 4441 || vm.envUint("EXPECTED_CHAIN_ID") != 4441) revert WrongChain();
        address owner = vm.envAddress("LITH_USDT_OWNER");
        if (owner == address(0)) revert InvalidOwner();

        vm.startBroadcast();
        token = new LithiumUSDT(owner);
        vm.stopBroadcast();
        emit Deployment(address(token), owner, block.chainid);
    }
}
