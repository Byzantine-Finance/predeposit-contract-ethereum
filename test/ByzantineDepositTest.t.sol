// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PauserRegistry} from "../src/permissions/PauserRegistry.sol";
import {ByzantineDeposit} from "../src/ByzantineDeposit.sol";
import {ERC4626Mock} from "./mocks/ERC4626Mock.t.sol";
import {ERC7535Mock} from "./mocks/ERC7535Mock.t.sol";
import {ERC7535} from "./mocks/ERC7535.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPauserRegistry} from "../src/interfaces/IPauserRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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

contract ERC7535MockZero is ERC7535Mock {
    constructor(string memory _name, string memory _symbol) ERC7535Mock(_name, _symbol) {}

    function deposit(uint256, address) public payable override returns (uint256 shares) {
        return 0;
    }
}

contract SmartContractUser {}

contract ByzantineDepositTest is Test {
    // Contract instances
    ByzantineDeposit public deposit;
    PauserRegistry public pauserRegistry;
    IERC20 public stETH;
    IwstETH public wstETH;
    IERC20 public fUSDC;

    SmartContractUser public scUser;

    // Byzantine Vaults Mocks
    ERC4626Mock public vault4626stETH;
    ERC4626Mock public vault4626fUSDC;
    ERC7535Mock public vault7535ETH;
    ERC7535MockZero public vault7535ETHZero;

    // ByzantineAdmin address
    address public byzantineAdmin = makeAddr("byzantineAdmin");
    // Pausers / unpauser addresses
    address[] public pausers = [makeAddr("pauser1"), makeAddr("pauser2")];
    address public unpauser = makeAddr("unpauser");
    // Depositors
    address[] public depositors = [makeAddr("alice"), makeAddr("bob")];
    address public alice = depositors[0];
    address public bob = depositors[1];
    address public charlie = makeAddr("charlie");

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
    string private RPC_URL = vm.envString("MAINNET_RPC_URL");
    uint256 private forkId;

    function setUp() public {
        // Set the testing environment
        forkId = vm.createSelectFork(RPC_URL);
        scUser = new SmartContractUser();

        // Contract addresses on Mainnet
        stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
        wstETH = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        fUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

        // Byzantine Vaults Mocks
        vault4626stETH = new ERC4626Mock(stETH, "stETH Byzantine Vault Shares", "byzStETH");
        vault4626fUSDC = new ERC4626Mock(fUSDC, "fUSDC Byzantine Vault Shares", "byzFUSDC");
        vault7535ETH = new ERC7535Mock("ETH Byzantine Vault Shares", "byzETH");
        vault7535ETHZero = new ERC7535MockZero("ETH Byzantine Vault Shares Z", "byzETHZ");

        // Deploy the PauserRegistry
        pauserRegistry = new PauserRegistry(pausers, unpauser);
        // Deploy the ByzantineDeposit contract
        deposit = new ByzantineDeposit(
            IPauserRegistry(address(pauserRegistry)), initialPausedStatus, byzantineAdmin, stETH, wstETH
        );

        // Set initial balance: ETH, stETH, fUSDC
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.deal(depositors[i], initialETHBalance);
            _getStETH(depositors[i], initialStETHBalance);
            deal(address(fUSDC), depositors[i], initialfUSDCBalance);
        }

        // Set up charlie's balances
        vm.deal(charlie, initialETHBalance);
        _getStETH(charlie, initialStETHBalance);
        deal(address(fUSDC), charlie, initialfUSDCBalance);

        // Whitelist alice and bob but not charlie
        vm.startPrank(byzantineAdmin);
        deposit.setCanDeposit(depositors, true);
        vm.stopPrank();

        assertEq(vm.activeFork(), forkId);
    }

    /* ===================== TEST PAUSABILITY ===================== */

    function test_PauseFunctions() public {
        // Alice deposits ETH and stETH and withdraw some: initial contract state
        _depositETH(alice, 5 ether);
        _depositStETH(alice, 5 ether);
        _withdraw(alice, beaconChainETHToken, 1 ether);

        // Should revert if vault moves are paused
        vm.prank(alice);
        vm.expectRevert(bytes("Pausable: index is paused"));
        deposit.moveToVault(stETH, address(vault4626stETH), 1 ether, alice, 1 ether);

        // Unpause vault moves
        _unpauseVaultMoves();
        _recordVaults();

        // Alice should be able to move ETH
        vm.prank(alice);
        deposit.moveToVault(stETH, address(vault4626stETH), 1 ether, alice, 1 ether);

        // Pause deposits and vault moves
        vm.startPrank(pausers[0]);
        deposit.pause(deposit.paused() | (1 << PAUSED_DEPOSITS | 1 << PAUSED_VAULTS_MOVES));
        vm.stopPrank();

        // Should revert now that vault moves and deposits are paused
        vm.startPrank(alice);
        vm.expectRevert(bytes("Pausable: index is paused"));
        deposit.moveToVault(stETH, address(vault4626stETH), 1 ether, alice, 1 ether);
        vm.expectRevert(bytes("Pausable: index is paused"));
        deposit.depositETH{value: 1 ether}();
        stETH.approve(address(deposit), 1 ether);
        vm.expectRevert(bytes("Pausable: index is paused"));
        deposit.depositERC20(stETH, 1 ether);
        vm.stopPrank();
    }

    /* ===================== TEST ADMIN FUNCTIONS ===================== */

    function test_setCanDeposit() public {
        // Should revert if non byzantineAdmin whitelists
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        deposit.setCanDeposit(_createArrayOfOne(charlie), true);
        vm.stopPrank();

        // Alice deposits stETH
        _depositStETH(alice, 5 ether);

        // Unwhitelist Alice
        vm.prank(byzantineAdmin);
        deposit.setCanDeposit(_createArrayOfOne(alice), false);

        // Verify that Alice cannot deposit anymore
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAuthorizedToDeposit.selector, alice));
        deposit.depositETH{value: 1 ether}();
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAuthorizedToDeposit.selector, alice));
        deposit.depositERC20(stETH, 1 ether);
        vm.stopPrank();

        // Unpause vault moves
        _unpauseVaultMoves();
        _recordVaults();

        // Alice shoudn't be able to move her stETH to the vault
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAuthorizedToMoveFunds.selector, alice));
        deposit.moveToVault(stETH, address(vault4626stETH), 3 ether, alice, 3 ether);
    }

    function test_AddDepositToken() public {
        // Verify that it's not possible to deposit non whitelisted tokens
        vm.startPrank(alice);
        fUSDC.approve(address(deposit), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAllowedDepositToken.selector, fUSDC));
        deposit.depositERC20(fUSDC, 1 ether);
        vm.stopPrank();

        // Add fUSDC as a deposit token
        vm.prank(byzantineAdmin);
        deposit.addDepositToken(fUSDC);

        // Verify that it's possible to deposit fUSDC
        _depositfUSDC(alice, 1 ether);
    }

    function test_RemoveDepositToken() public {
        // Remove beacon ETH as a deposit token
        vm.prank(byzantineAdmin);
        deposit.removeDepositToken(beaconChainETHToken);

        // Verify that it's not possible to deposit beacon ETH
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAllowedDepositToken.selector, beaconChainETHToken));
        deposit.depositETH{value: 1 ether}();
    }

    function test_setPermissionlessDeposit() public {
        // Verify that Charlie cannot deposit
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAuthorizedToDeposit.selector, charlie));
        deposit.depositETH{value: 0.5 ether}();

        // Set permissionless deposit to true
        vm.prank(byzantineAdmin);
        deposit.setPermissionlessDeposit(true);

        // Verify that's non whitelisted depositors can deposit
        _depositETH(charlie, 0.5 ether);
    }

    function test_delistVault() public {
        _recordVaults();

        // Delist the vault
        vm.prank(byzantineAdmin);
        deposit.delistByzantineVault(address(vault7535ETH));
        assertEq(deposit.isByzantineVault(address(vault7535ETH)), false);
    }

    /* ===================== TEST EXTERNAL FUNCTIONS ===================== */

    function test_depositETH_ZeroValue() public {
        vm.startPrank(alice);
        vm.expectRevert(ByzantineDeposit.ZeroETHSent.selector);
        deposit.depositETH();
    }

    function test_withdraw_failTransferEth() public {
        vm.startPrank(byzantineAdmin);
        deposit.setCanDeposit(_createArrayOfOne(address(scUser)), true);

        deal(address(scUser), 1 ether);
        vm.startPrank(address(scUser));
        deposit.depositETH{value: 1 ether}();

        IERC20 token = deposit.beaconChainETHToken();
        vm.expectRevert(ByzantineDeposit.ETHTransferFailed.selector);
        deposit.withdraw(token, 1 ether, address(scUser));
    }

    function test_DepositWithdrawMoveETH(uint256 initialDeposit, uint256 withdrawnAmount) public {
        vm.assume(initialDeposit > 0 && withdrawnAmount > 0);
        vm.assume(initialDeposit <= initialStETHBalance);
        vm.assume(withdrawnAmount <= initialDeposit);

        // Alice deposits `initialDeposit` ETH
        _depositETH(alice, initialDeposit);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), initialDeposit);
        assertEq(address(deposit).balance, initialDeposit);
        assertEq(alice.balance, initialStETHBalance - initialDeposit);

        // Withdrawal failed if it exceeds the deposited amount
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ByzantineDeposit.InsufficientDepositedBalance.selector, alice, beaconChainETHToken)
        );
        deposit.withdraw(beaconChainETHToken, initialDeposit + 1 ether, alice);

        // Alice withdraws some ETH
        _withdraw(alice, beaconChainETHToken, withdrawnAmount);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), initialDeposit - withdrawnAmount);
        assertEq(address(deposit).balance, initialDeposit - withdrawnAmount);
        assertEq(alice.balance, initialStETHBalance - initialDeposit + withdrawnAmount);

        // Unpause vault moves
        _unpauseVaultMoves();
        // Record the vault
        _recordVaults();

        // Vault moves failed if it exceeds the deposited amount
        vm.startPrank(alice);
        uint256 minSharesOut = vault7535ETH.previewDeposit(initialDeposit - withdrawnAmount + 0.1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ByzantineDeposit.InsufficientDepositedBalance.selector, alice, beaconChainETHToken)
        );
        deposit.moveToVault(
            beaconChainETHToken,
            address(vault7535ETH),
            (initialDeposit - withdrawnAmount) + 0.1 ether,
            alice,
            minSharesOut
        );
        vm.stopPrank();

        // Alice moves all her ETH to the vault (works with 4626 because that's the initial deposit)
        _moveToVault(alice, beaconChainETHToken, address(vault7535ETH), initialDeposit - withdrawnAmount);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, beaconChainETHToken), 0);
        assertEq(address(deposit).balance, 0);
        assertEq(alice.balance, initialStETHBalance - initialDeposit + withdrawnAmount);
        assertEq(vault7535ETH.balanceOf(alice), initialDeposit - withdrawnAmount); // vault shares
        assertEq(address(vault7535ETH).balance, initialDeposit - withdrawnAmount); // vault assets
    }

    function test_DepositWithdrawMoveStETH(uint256 initialAliceDeposit, uint256 initialBobDeposit) public {
        vm.assume((initialAliceDeposit > 2 wei) && (initialBobDeposit > 2 wei));
        vm.assume(initialAliceDeposit <= initialStETHBalance && initialBobDeposit <= initialStETHBalance);

        // Alice deposits `initialAliceDeposit` stETH
        _depositStETH(alice, initialAliceDeposit);
        uint256 wstETHAmountAlice = deposit.depositedAmount(alice, stETH);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, stETH), wstETHAmountAlice);
        assertApproxEqAbs(stETH.balanceOf(alice), initialStETHBalance - initialAliceDeposit, 2);

        // Simulate stETH rebasing (only for alice here)
        uint256 rebasingAmount = 0 ether;
        _rebaseStETH(rebasingAmount);

        // Bob deposits `initialBobDeposit` stETH
        _depositStETH(bob, initialBobDeposit);
        uint256 wstETHAmountBob = deposit.depositedAmount(bob, stETH);

        // Simulate stETH rebasing (for both alice and bob)
        _rebaseStETH(2 * rebasingAmount);

        // Alice withdraws all her stETH
        _withdraw(alice, stETH, wstETHAmountAlice);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, stETH), 0);
        assertApproxEqAbs(stETH.balanceOf(alice), initialStETHBalance, 3);

        // Unpause vault moves
        _unpauseVaultMoves();
        // Record the vault
        _recordVaults();

        // Bob moves almost all his stETH to the vault
        _moveToVault(bob, stETH, address(vault4626stETH), wstETHAmountBob - 1 wei);

        // Verify balances
        assertEq(deposit.depositedAmount(bob, stETH), 1 wei);
        assertApproxEqAbs(stETH.balanceOf(bob), initialStETHBalance - initialBobDeposit, 3);
        assertApproxEqAbs(
            vault4626stETH.balanceOf(bob), initialBobDeposit - ILido(address(stETH)).getPooledEthByShares(1 wei), 3
        ); // vault shares
        assertApproxEqAbs(
            stETH.balanceOf(address(vault4626stETH)),
            initialBobDeposit - ILido(address(stETH)).getPooledEthByShares(1 wei),
            3
        ); // vault assets
    }

    function test_DepositWithdrawMovefUSDC(
        uint256 initialDeposit,
        uint256 withdrawnAmount,
        uint256 amountToMove
    ) public {
        vm.assume(initialDeposit > 0 && withdrawnAmount > 0 && amountToMove > 0);
        vm.assume(initialDeposit <= initialfUSDCBalance / 2);
        vm.assume(withdrawnAmount <= 2 * initialDeposit);
        vm.assume(amountToMove <= 2 * initialDeposit - withdrawnAmount);

        // Byzantine Admin whitelists fUSDC
        vm.prank(byzantineAdmin);
        deposit.addDepositToken(fUSDC);

        // Alice deposits `initialDeposit` fUSDC
        _depositfUSDC(alice, initialDeposit);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, fUSDC), initialDeposit);
        assertEq(fUSDC.balanceOf(alice), initialfUSDCBalance - initialDeposit);

        // Alice deposits `initialDeposit` fUSDC again
        _depositfUSDC(alice, initialDeposit);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, fUSDC), 2 * initialDeposit);
        assertEq(fUSDC.balanceOf(alice), initialfUSDCBalance - 2 * initialDeposit);

        // Alice withdraws some fUSDC
        _withdraw(alice, fUSDC, withdrawnAmount);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, fUSDC), 2 * initialDeposit - withdrawnAmount);
        assertEq(fUSDC.balanceOf(alice), initialfUSDCBalance - 2 * initialDeposit + withdrawnAmount);

        // Unpause vault moves
        _unpauseVaultMoves();
        // Record the vault
        _recordVaults();

        // Bob moves almost all his fUSDC to the vault
        _moveToVault(alice, fUSDC, address(vault4626fUSDC), amountToMove);

        // Verify balances
        assertEq(deposit.depositedAmount(alice, fUSDC), 2 * initialDeposit - withdrawnAmount - amountToMove);
        assertEq(fUSDC.balanceOf(alice), initialfUSDCBalance - 2 * initialDeposit + withdrawnAmount);
        assertEq(vault4626fUSDC.balanceOf(alice), amountToMove); // vault shares
        assertEq(fUSDC.balanceOf(address(vault4626fUSDC)), amountToMove); // vault assets
    }

    function test_Move_MismatchedVaultReverts() public {
        vm.prank(byzantineAdmin);
        deposit.addDepositToken(fUSDC);

        // Alice deposits various assets
        _depositETH(alice, 5 ether);
        _depositStETH(alice, 5 ether);
        _depositfUSDC(alice, 5 ether);

        // Unpause vault moves
        _unpauseVaultMoves();

        // Record the vaults
        _recordVaults();

        // Case 1: Should revert when trying to move ETH
        vm.startPrank(alice);
        vm.expectRevert(ByzantineDeposit.MismatchingAssets.selector);
        deposit.moveToVault(beaconChainETHToken, address(vault4626fUSDC), 5 ether, alice, 5 ether);

        // Case 2: Should revert when trying to move ERC20 tokens to a ERC7535 vault
        uint256 depositAmount = deposit.depositedAmount(alice, stETH);
        vm.expectRevert(ByzantineDeposit.MismatchingAssets.selector);
        deposit.moveToVault(stETH, address(vault7535ETH), depositAmount, alice, depositAmount);

        // Case 3: Should revert when trying to move mismatched ERC20 tokens to a ERC4626 vault
        // testing with mainnet, revert reason from stETH.transferFrom() is ALLOWANCE_EXCEEDED
        vm.expectRevert(ByzantineDeposit.MismatchingAssets.selector);
        deposit.moveToVault(fUSDC, address(vault4626stETH), 5 ether, alice, 5 ether);
    }

    function test_moveToVault_RevertWhen_ZeroShares() public {
        // Alice deposits 1 ETH
        _depositETH(alice, 1 ether);

        // Unpause vault moves and record the vaults
        _unpauseVaultMoves();
        _recordVaults();

        // Alice moves 1 ETH to the vault
        vm.startPrank(alice);
        vm.expectRevert(ByzantineDeposit.InsufficientSharesReceived.selector);
        deposit.moveToVault(beaconChainETHToken, address(vault7535ETHZero), 1 ether, alice, 1 ether);
    }

    function test_ReceiverIsZeroAddress() public {
        // Alice deposits 1 ETH
        _depositETH(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(ByzantineDeposit.ReceiverIsZeroAddress.selector);
        deposit.withdraw(beaconChainETHToken, 1 ether, address(0));

        // Unpause vault moves and record the vaults
        _unpauseVaultMoves();
        _recordVaults();

        // Alice moves 1 ETH to the vault
        vm.startPrank(alice);
        vm.expectRevert(ByzantineDeposit.ReceiverIsZeroAddress.selector);
        deposit.moveToVault(beaconChainETHToken, address(vault7535ETHZero), 1 ether, address(0), 1 ether);
    }

    function test_Move_RevertWhenNonRecordedVault() public {
        // Alice deposits 5 ETH
        _depositStETH(alice, 5 ether);
        _depositETH(alice, 5 ether);

        // Unpause withdrawals
        _unpauseVaultMoves();

        // Should revert when trying to move to a non recorded vault
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAllowedVault.selector, address(vault4626stETH)));
        deposit.moveToVault(stETH, address(vault4626stETH), 5 ether, alice, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(ByzantineDeposit.NotAllowedVault.selector, address(vault7535ETH)));
        deposit.moveToVault(beaconChainETHToken, address(vault7535ETH), 5 ether, alice, 5 ether);
        vm.stopPrank();
    }

    /* ===================== HELPER FUNCTIONS ===================== */

    // deposit ETH to the contract
    function _depositETH(address depositor, uint256 amount) internal {
        vm.prank(depositor);
        deposit.depositETH{value: amount}();
    }

    // deposit stETH to the contract
    function _depositStETH(address depositor, uint256 amount) internal {
        vm.startPrank(depositor);
        stETH.approve(address(deposit), amount);
        deposit.depositERC20(stETH, amount);
        vm.stopPrank();
    }

    // deposit fUSDC to the contract
    function _depositfUSDC(address depositor, uint256 amount) internal {
        vm.startPrank(depositor);
        fUSDC.approve(address(deposit), amount);
        deposit.depositERC20(fUSDC, amount);
        vm.stopPrank();
    }

    // withdraw tokens from the contract
    function _withdraw(address withdrawer, IERC20 token, uint256 amount) internal {
        vm.prank(withdrawer);
        deposit.withdraw(token, amount, withdrawer);
    }

    // move tokens to a vault
    function _moveToVault(address staker, IERC20 token, address vault, uint256 amount) internal {
        uint256 minSharesOut = IERC4626(vault).previewDeposit(amount);
        vm.prank(staker);
        deposit.moveToVault(token, vault, amount, staker, minSharesOut);
    }

    // record created vaults
    function _recordVaults() internal {
        address[] memory vaults = new address[](4);
        vaults[0] = address(vault4626stETH);
        vaults[1] = address(vault4626fUSDC);
        vaults[2] = address(vault7535ETH);
        vaults[3] = address(vault7535ETHZero);
        vm.prank(byzantineAdmin);
        deposit.recordByzantineVaults(vaults);
    }

    // stake ETH on Lido
    function _getStETH(address staker, uint256 amount) internal {
        vm.prank(staker);
        ILido(address(stETH)).submit{value: amount}(staker);
    }

    // Simulate stETH rebasing
    function _rebaseStETH(
        uint256 amount
    ) internal {
        // vm.warp(block.timestamp + 2 days);
        // vm.prank(charlie);
        // stETH.transfer(address(wstETH), amount);
        /// TODO: find a way to simulate stETH rebasing on foundry tests
    }

    function _unpauseVaultMoves() internal {
        vm.startPrank(unpauser);
        deposit.unpause(deposit.paused() & ~(1 << PAUSED_VAULTS_MOVES));
        vm.stopPrank();
    }

    function _createArrayOfOne(
        address addr
    ) internal pure returns (address[] memory array) {
        array = new address[](1);
        array[0] = addr;
    }
}
