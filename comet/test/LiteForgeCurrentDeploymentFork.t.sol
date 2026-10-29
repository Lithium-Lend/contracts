// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";

interface CurrentMarket {
    function supplyNative() external payable;
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function governor() external view returns (address);
    function pauseGuardian() external view returns (address);
    function baseTokenPriceFeed() external view returns (address);
    function assetList() external view returns (address);
    function baseToken() external view returns (address);
    function collateralBalanceOf(address account, address asset) external view returns (uint128);
}

interface CurrentTestToken {
    function faucet() external returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev All transactions execute only on a local, pinned fork.
contract LiteForgeCurrentDeploymentForkTest is Test {
    string internal baseline;
    address internal user = address(0xA0D17);
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function setUp() public {
        if (!vm.envOr("LITHIUM_COMET_FORK", false)) {
            vm.skip(true);
            return;
        }
        baseline = vm.readFile("config/liteforge-attestation.json");
        vm.createSelectFork(
            vm.envOr("LITEFORGE_RPC_URL", string("https://liteforge.rpc.caldera.xyz/http")),
            vm.parseJsonUint(baseline, ".referenceBlock.number")
        );
        vm.setEvmVersion("prague");
        assertEq(block.chainid, 4441);
        vm.deal(user, 3 ether);
    }

    function field(uint256 index, string memory name) internal view returns (address) {
        return vm.parseJsonAddress(baseline, string.concat(".markets[", vm.toString(index), "].", name));
    }

    function testCurrentImplementationsAndAuthoritiesMatchBaseline() public view {
        for (uint256 i; i < 3; i++) {
            address proxy = field(i, "proxy");
            CurrentMarket market = CurrentMarket(proxy);
            assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), field(i, "implementation"));
            assertEq(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))), field(i, "admin"));
            assertEq(market.governor(), field(i, "governor"));
            assertEq(market.pauseGuardian(), field(i, "pauseGuardian"));
            assertEq(market.baseToken(), field(i, "baseToken"));
            assertEq(market.baseTokenPriceFeed(), field(i, "baseTokenPriceFeed"));
            assertEq(market.assetList(), field(i, "assetList"));
        }
    }

    function testAllCurrentMarketsAcceptAndReturnCollateral() public {
        vm.startPrank(user);
        for (uint256 i; i < 2; i++) {
            CurrentMarket market = CurrentMarket(field(i, "proxy"));
            market.supplyNative{value: 1 ether}();
            assertEq(market.collateralBalanceOf(user, address(0)), 1 ether);
            market.withdraw(address(0), 1 ether);
            assertEq(market.collateralBalanceOf(user, address(0)), 0);
        }
        CurrentMarket nativeMarket = CurrentMarket(field(2, "proxy"));
        CurrentTestToken token = CurrentTestToken(field(2, "collateralToken"));
        token.faucet();
        uint256 beforeBalance = token.balanceOf(user);
        assertTrue(token.approve(address(nativeMarket), 1000e6));
        nativeMarket.supply(address(token), 1000e6);
        assertEq(nativeMarket.collateralBalanceOf(user, address(token)), 1000e6);
        nativeMarket.withdraw(address(token), 1000e6);
        assertEq(nativeMarket.collateralBalanceOf(user, address(token)), 0);
        assertEq(token.balanceOf(user), beforeBalance);
        vm.stopPrank();
        assertEq(user.balance, 3 ether);
    }
}
