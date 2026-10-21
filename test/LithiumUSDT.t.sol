// SPDX-License-Identifier: LicenseRef-Lithium-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LithiumUSDT} from "../src/testnet/LithiumUSDT.sol";
import {DeployLithiumUSDT} from "../script/DeployLithiumUSDT.s.sol";

contract USDTFaucetCaller {
    function claim(LithiumUSDT token) external {
        token.faucet();
    }
}

contract LithiumUSDTTest is Test {
    LithiumUSDT internal token;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant CLAIM = 10_000e6;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event FaucetClaimed(address indexed account, uint256 amount, uint256 nextClaimAt);

    function setUp() public {
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        token = new LithiumUSDT(address(this));
    }

    function claim(address account) internal {
        vm.prank(account);
        assertEq(token.faucet(), CLAIM);
    }

    function testExactMetadata() public view {
        assertEq(token.name(), "Lithium USDT");
        assertEq(token.symbol(), "lithUSDT");
        assertEq(token.decimals(), 6);
        assertEq(token.CHAIN_ID(), 4441);
    }

    function testNoImplicitInitialMint() public view {
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testOwnerAndFaucetSettings() public view {
        assertEq(token.owner(), address(this));
        assertEq(token.faucetAmount(), CLAIM);
        assertEq(token.faucetCooldown(), 1 days);
    }

    function testConstructorRejectsMainnet() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.LiteForgeOnly.selector, 1));
        new LithiumUSDT(address(this));
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LithiumUSDT(address(0));
    }

    function testOwnerMintsExactAmount() public {
        token.mint(alice, 123_456_789);
        assertEq(token.balanceOf(alice), 123_456_789);
        assertEq(token.totalSupply(), 123_456_789);
    }

    function testMintEmitsStandardTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(0), alice, 1e6);
        token.mint(alice, 1e6);
    }

    function testNonOwnerCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice, 1e6);
        assertEq(token.totalSupply(), 0);
    }

    function testMintRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1e6);
    }

    function testMintRejectsWrongRuntimeChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.LiteForgeOnly.selector, 1));
        token.mint(alice, 1e6);
    }

    function testFirstClaimNeedsNoApproval() public {
        claim(alice);
        assertEq(token.balanceOf(alice), CLAIM);
        assertEq(token.totalSupply(), CLAIM);
        assertEq(token.allowance(alice, address(token)), 0);
    }

    function testClaimEmitsAmountAndNextTimestamp() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit FaucetClaimed(alice, CLAIM, block.timestamp + 1 days);
        vm.prank(alice);
        token.faucet();
    }

    function testImmediateRepeatRejected() public {
        claim(alice);
        uint256 next = token.nextFaucetAt(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.FaucetCooldownActive.selector, next));
        token.faucet();
        assertEq(token.balanceOf(alice), CLAIM);
        assertEq(token.nextFaucetAt(alice), next);
    }

    function testOneSecondBeforeCooldownRejected() public {
        claim(alice);
        uint256 next = token.nextFaucetAt(alice);
        vm.warp(next - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.FaucetCooldownActive.selector, next));
        token.faucet();
    }

    function testExactCooldownBoundaryAllowed() public {
        claim(alice);
        uint256 next = token.nextFaucetAt(alice);
        vm.warp(next);
        claim(alice);
        assertEq(token.balanceOf(alice), 2 * CLAIM);
        assertEq(token.nextFaucetAt(alice), next + 1 days);
    }

    function testLateClaimDoesNotAccumulateMissedAllocations() public {
        claim(alice);
        vm.warp(token.nextFaucetAt(alice) + 365 days);
        claim(alice);
        assertEq(token.balanceOf(alice), 2 * CLAIM);
    }

    function testFirstClaimAtTimestampZeroWorks() public {
        vm.warp(0);
        claim(alice);
        assertEq(token.nextFaucetAt(alice), 1 days);
    }

    function testIndependentWalletCooldowns() public {
        claim(alice);
        claim(bob);
        assertEq(token.totalSupply(), 2 * CLAIM);
        assertEq(token.balanceOf(bob), CLAIM);
    }

    function testSendingAwayTokensDoesNotResetCooldown() public {
        claim(alice);
        vm.prank(alice);
        token.transfer(bob, CLAIM);
        uint256 next = token.nextFaucetAt(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.FaucetCooldownActive.selector, next));
        token.faucet();
    }

    function testOwnerMintDoesNotResetOrConsumeRecipientCooldown() public {
        token.mint(alice, 1e6);
        assertEq(token.nextFaucetAt(alice), 0);
        claim(alice);
        uint256 next = token.nextFaucetAt(alice);
        token.mint(alice, 1e6);
        assertEq(token.nextFaucetAt(alice), next);
    }

    function testFaucetRejectsWrongRuntimeChain() public {
        vm.chainId(11155111);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.LiteForgeOnly.selector, 11155111));
        token.faucet();
        assertEq(token.nextFaucetAt(alice), 0);
    }

    function testContractWalletClaimsToItself() public {
        USDTFaucetCaller caller = new USDTFaucetCaller();
        caller.claim(token);
        assertEq(token.balanceOf(address(caller)), CLAIM);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFaucetCannotChooseAnotherRecipient() public {
        (bool success,) = address(token).call(abi.encodeWithSignature("faucet(address)", alice));
        assertFalse(success);
        assertEq(token.nextFaucetAt(alice), 0);
    }

    function testTokenDoesNotAcceptNativePayment() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(token).call{value: 1}(abi.encodeCall(token.faucet, ()));
        assertFalse(success);
        assertEq(token.totalSupply(), 0);
    }

    function testTransferHasNoFee() public {
        claim(alice);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 25e6));
        assertEq(token.balanceOf(alice), CLAIM - 25e6);
        assertEq(token.balanceOf(bob), 25e6);
        assertEq(token.totalSupply(), CLAIM);
    }

    function testApprovalSpendingHasExactDeltas() public {
        claim(alice);
        vm.prank(alice);
        token.approve(address(this), 40e6);
        token.transferFrom(alice, bob, 30e6);
        assertEq(token.allowance(alice, address(this)), 10e6);
        assertEq(token.balanceOf(bob), 30e6);
        assertEq(token.balanceOf(alice), CLAIM - 30e6);
    }

    function testInfiniteApprovalRemainsInfinite() public {
        claim(alice);
        vm.prank(alice);
        token.approve(address(this), type(uint256).max);
        token.transferFrom(alice, bob, CLAIM);
        assertEq(token.allowance(alice, address(this)), type(uint256).max);
    }

    function testOwnerCannotSpendWithoutAllowance() public {
        claim(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function testOverdrawRevertsWithoutChangingSupply() public {
        claim(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, CLAIM, CLAIM + 1));
        token.transfer(bob, CLAIM + 1);
        assertEq(token.totalSupply(), CLAIM);
    }

    function testZeroAddressTransferRejected() public {
        claim(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testSelfTransferPreservesBalanceAndSupply() public {
        claim(alice);
        vm.prank(alice);
        token.transfer(alice, CLAIM);
        assertEq(token.balanceOf(alice), CLAIM);
        assertEq(token.totalSupply(), CLAIM);
    }

    function testOwnershipRequiresAcceptance() public {
        token.transferOwnership(bob);
        assertEq(token.owner(), address(this));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        token.mint(bob, 1);
        vm.prank(bob);
        token.acceptOwnership();
        assertEq(token.owner(), bob);
        vm.prank(bob);
        token.mint(bob, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.mint(alice, 1);
    }

    function testWrongAccountCannotAcceptOwnership() public {
        token.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.acceptOwnership();
    }

    function testRenouncingDisablesAdminMintButNotFaucet() public {
        token.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.mint(alice, 1);
        claim(alice);
        assertEq(token.balanceOf(alice), CLAIM);
    }

    function testFuzzTransferConservesSupply(uint128 minted, uint128 sent) public {
        uint256 amount = bound(sent, 0, minted);
        token.mint(alice, minted);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), token.totalSupply());
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzzClaimCooldown(uint32 elapsed) public {
        claim(alice);
        uint256 next = token.nextFaucetAt(alice);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.prank(alice);
        if (elapsed < 1 days) {
            vm.expectRevert(abi.encodeWithSelector(LithiumUSDT.FaucetCooldownActive.selector, next));
            token.faucet();
            assertEq(token.totalSupply(), CLAIM);
        } else {
            token.faucet();
            assertEq(token.totalSupply(), 2 * CLAIM);
        }
    }

    function testFuzzOnlyOwnerMints(address caller) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        token.mint(caller, 1);
    }

    // Keep process-wide environment mutation in one test to avoid parallel races.
    function testDeploymentScriptGuardsAndMetadata() public {
        DeployLithiumUSDT deployer = new DeployLithiumUSDT();
        vm.setEnv("EXPECTED_CHAIN_ID", "4441");
        vm.setEnv("LITH_USDT_OWNER", vm.toString(bob));
        LithiumUSDT deployed = deployer.run();
        assertEq(deployed.name(), "Lithium USDT");
        assertEq(deployed.symbol(), "lithUSDT");
        assertEq(deployed.owner(), bob);
        assertEq(deployed.totalSupply(), 0);

        vm.chainId(1);
        vm.expectRevert(DeployLithiumUSDT.WrongChain.selector);
        deployer.run();
        vm.chainId(4441);
        vm.setEnv("EXPECTED_CHAIN_ID", "1");
        vm.expectRevert(DeployLithiumUSDT.WrongChain.selector);
        deployer.run();
        vm.setEnv("EXPECTED_CHAIN_ID", "4441");
        vm.setEnv("LITH_USDT_OWNER", vm.toString(address(0)));
        vm.expectRevert(DeployLithiumUSDT.InvalidOwner.selector);
        deployer.run();
    }
}
