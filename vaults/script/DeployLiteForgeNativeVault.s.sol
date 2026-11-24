// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {NativeLendingFeeVault} from "../src/NativeLendingFeeVault.sol";

contract DeployLiteForgeNativeVault is Script {
    address internal constant MARKET = 0x2CF2179ff3732bd681eA59b339abF86a57922d3F;
    address internal constant ADMIN = 0x4f8705F8fb406FA933433EFE409bba16BE5c069B;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (NativeLendingFeeVault vault) {
        require(block.chainid == 4441, "Wrong network");
        address implementation = address(uint160(uint256(vm.load(MARKET, IMPLEMENTATION_SLOT))));
        require(
            implementation.codehash == 0x14326db51c7849f09c91c7d7e545cb277ec44933b5a0b39356daf7f76d8cda92,
            "Unexpected market implementation"
        );
        uint256 nonce = vm.envUint("VAULT_DEPLOY_NONCE");
        require(vm.getNonce(ADMIN) == nonce, "Deployer nonce changed");
        address expected = vm.computeCreateAddress(ADMIN, nonce);
        require(expected.code.length == 0, "Address in use");
        vm.startBroadcast(ADMIN);
        vault = new NativeLendingFeeVault(MARKET, ADMIN, ADMIN, 10_000 ether, "Lithium zkLTC Vault", "lvzkLTC");
        vm.stopBroadcast();
        require(address(vault) == expected && vault.maxDeposit(ADMIN) == 10_000 ether, "Unexpected vault state");
        console2.log("zkLTC vault", address(vault));
    }
}
