// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PauserRegistry} from "../src/permissions/PauserRegistry.sol";
import {ByzantineDeposit} from "../src/ByzantineDeposit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPauserRegistry} from "../src/interfaces/IPauserRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IwstETH} from "../src/ByzantineDeposit.sol";

import "forge-std/Test.sol";

interface ILido {
    function submit(
        address _referral
    ) external payable returns (uint256);
    function getPooledEthByShares(
        uint256 _sharesAmount
    ) external view returns (uint256);
}

interface IStETH is IERC20 {
    function getSharesByPooledEth(
        uint256
    ) external returns (uint256);
}

contract AuditFuzzTest is Test {
    // Contract instances
    ByzantineDeposit public deposit;
    PauserRegistry public pauserRegistry;
    IStETH public stETH;
    IwstETH public wstETH;
    IERC20 public fUSDC;

    // admin address
    address public admin = makeAddr("admin");
    // Pausers / unpauser addresses
    address[] public pausers = [makeAddr("pauser1"), makeAddr("pauser2")];
    address public unpauser = makeAddr("unpauser");
    // Depositors
    address[] public depositors = [makeAddr("alice"), makeAddr("bob")];
    address public alice = depositors[0];
    address public bob = depositors[1];

    // Initial balances
    uint256 public initialETHBalance = 200 ether;
    uint256 public initialStETHBalance = 100 ether;
    uint256 public initialfUSDCBalance = 100 ether;

    // Canonical, virtual beacon chain ETH token
    IERC20 public constant beaconChainETHToken = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Pause indices flags
    uint8 private constant PAUSED_DEPOSITS = 0;
    uint8 private constant PAUSED_VAULTS_MOVES = 1;
    // Initial paused status
    uint256 private initialPausedStatus = 1 << PAUSED_VAULTS_MOVES;

    // RPC URL of the test environnement
    string private RPC_URL = vm.envString("HOLESKY_RPC_URL");
    uint256 private forkId;

    function setUp() public {
        // Set the testing environment
        forkId = vm.createSelectFork(RPC_URL);

        // Contract addresses on Holesky
        stETH = IStETH(0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034);
        wstETH = IwstETH(0x8d09a4502Cc8Cf1547aD300E066060D043f6982D);
        fUSDC = IERC20(0x74A4A85C611679B73F402B36c0F84A7D2CcdFDa3);

        // Deploy the PauserRegistry
        pauserRegistry = new PauserRegistry(pausers, unpauser);
        // Deploy the ByzantineDeposit contract
        deposit =
            new ByzantineDeposit(IPauserRegistry(address(pauserRegistry)), initialPausedStatus, admin, stETH, wstETH);

        // Set initial balance: ETH, stETH, fUSDC
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.deal(depositors[i], initialETHBalance);
            _getStETH(depositors[i], initialStETHBalance);
            deal(address(fUSDC), depositors[i], initialfUSDCBalance);
        }

        vm.startPrank(admin);
        deposit.setCanDeposit(depositors, true);
        vm.stopPrank();

        assertEq(vm.activeFork(), forkId);
    }

    function _getStETH(address staker, uint256 amount) internal {
        vm.prank(staker);
        ILido(address(stETH)).submit{value: amount + 1}(staker);
    }

    function test_deposit_ETH(
        uint256 depositAmount
    ) public {
        // zero deposit not allowed
        depositAmount = bound(depositAmount, 1, 100_000_000 ether);
        vm.deal(alice, depositAmount);
        uint256 ethAliceBalance = address(alice).balance;

        vm.prank(alice);
        deposit.depositETH{value: depositAmount}();

        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), depositAmount);
        assertEq(address(deposit).balance, depositAmount);
        assertEq(address(alice).balance, ethAliceBalance - depositAmount);
    }

    function test_double_deposit_ETH(uint256 depositAmount, uint256 depositAmount2) public {
        // zero deposit not allowed
        depositAmount = bound(depositAmount, 1, 100_000_000 ether);
        depositAmount2 = bound(depositAmount2, 1, 100_000_000 ether);
        vm.deal(alice, depositAmount);
        vm.deal(bob, depositAmount2);

        vm.prank(alice);
        deposit.depositETH{value: depositAmount}();
        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), depositAmount);
        assertEq(address(deposit).balance, depositAmount);
        assertEq(address(alice).balance, 0);

        vm.prank(bob);
        deposit.depositETH{value: depositAmount2}();
        assertEq(deposit.depositedAmount(bob, beaconChainETHToken), depositAmount2);
        assertEq(address(deposit).balance, depositAmount + depositAmount2);
        assertEq(address(bob).balance, 0);
    }

    function test_withdraw_ETH(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1, 100_000_000 ether);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        vm.deal(alice, depositAmount);
        uint256 ethAliceBalance = address(alice).balance;

        vm.prank(alice);
        deposit.depositETH{value: depositAmount}();

        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), depositAmount);
        assertEq(address(deposit).balance, depositAmount);
        assertEq(address(alice).balance, ethAliceBalance - depositAmount);

        vm.prank(alice);
        deposit.withdraw(beaconChainETHToken, withdrawAmount, alice);

        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), depositAmount - withdrawAmount);
        assertEq(address(deposit).balance, depositAmount - withdrawAmount);
        assertEq(address(alice).balance, ethAliceBalance - depositAmount + withdrawAmount);
    }

    function test_deposit_wstETH(
        uint256 depositAmount
    ) public {
        // zero deposit not allowed
        depositAmount = bound(depositAmount, 1, 100_000_000 ether);
        deal(address(wstETH), alice, depositAmount);

        vm.startPrank(alice);
        wstETH.approve(address(deposit), depositAmount);
        deposit.depositERC20(wstETH, depositAmount);
        vm.stopPrank();

        assertEq(wstETH.balanceOf(address(deposit)), depositAmount);
        assertEq(wstETH.balanceOf(alice), 0);
        assertEq(deposit.depositedAmount(alice, wstETH), depositAmount);
    }

    function test_withdraw_wstETH(uint256 depositAmount, uint256 withdrawAmount) public {
        // zero deposit not allowed
        depositAmount = bound(depositAmount, 1, 100_000_000 ether);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        deal(address(wstETH), alice, depositAmount);

        vm.startPrank(alice);
        wstETH.approve(address(deposit), depositAmount);
        deposit.depositERC20(wstETH, depositAmount);
        vm.stopPrank();

        assertEq(wstETH.balanceOf(address(deposit)), depositAmount);
        assertEq(wstETH.balanceOf(alice), 0);
        assertEq(deposit.depositedAmount(alice, wstETH), depositAmount);

        vm.prank(alice);
        deposit.withdraw(wstETH, withdrawAmount, alice);

        assertEq(wstETH.balanceOf(address(deposit)), depositAmount - withdrawAmount);
        assertEq(wstETH.balanceOf(alice), withdrawAmount);
        assertEq(deposit.depositedAmount(alice, wstETH), depositAmount - withdrawAmount);
    }
}
