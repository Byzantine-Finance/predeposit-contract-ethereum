// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "./permissions/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7535} from "./interfaces/IERC7535.sol";
import {IPauserRegistry} from "./interfaces/IPauserRegistry.sol";

/**
 * @notice Interface for the stETH token wrapper
 * @dev It's an ERC20 token that represents the account's share of the total
 * supply of stETH tokens. WstETH token's balance only changes on transfers,
 * unlike StETH that is also changed when oracles report staking rewards and
 * penalties. It's a "power user" token for DeFi protocols which don't
 * support rebasable tokens.
 */
interface IwstETH is IERC20 {
    function wrap(
        uint256 _stETHAmount
    ) external returns (uint256);
    function unwrap(
        uint256 _wstETHAmount
    ) external returns (uint256);
}

/**
 * @title ByzantineDeposit contract to allow early liquidity provider to deposit on the Byzantine procotol
 * @author Byzantine Finance
 * @notice This contract allows the deposit of any token as long as it is whitelisted as a deposit token.
 *         Deposits will be allowed for whitelisted addresses only.
 *         The possibility to allow public and permissionless deposits could be activated in the future.
 * @dev The canonical address for the beacon chain ETH is 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
 *      stablecoins, wrapped BTC, iBTC and any other ERC20 can be whitelisted as long as they're not rebasing
 *      /!\ stETH is the only rebasing token allowed /!\
 */
contract ByzantineDeposit is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ============== EVENTS ============== */

    event Deposit(address indexed sender, IERC20 token, uint256 amount);
    event Withdraw(address indexed sender, IERC20 token, uint256 amount);
    event MoveToVault(address indexed owner, IERC20 token, address vault, uint256 amount, address receiver);
    event DepositorStatusChanged(address indexed depositor, bool canDeposit);
    event DepositTokenAdded(IERC20 token);
    event PermissionlessDepositSet(bool permissionlessDeposit);

    /* ============== CONSTANTS + IMMUTABLES ============== */

    /// @dev Index for flag that pauses deposits when set
    uint8 internal constant PAUSED_DEPOSITS = 0;

    /// @dev Index for flag that pauses withdrawals when set.
    uint8 internal constant PAUSED_WITHDRAWALS = 1;

    /// @dev Index for flag that pauses Byzantine vaults moves when set.
    uint8 internal constant PAUSED_VAULTS_MOVES = 2;

    /// @dev Canonical, virtual beacon chain ETH token
    IERC20 public constant beaconChainETHToken = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @dev Contract address of the stETH token
    IERC20 public immutable stETHToken;

    /// @dev Contract address of the wstETH token
    IwstETH public immutable wstETH;

    /* ============== STATE VARIABLES ============== */

    /// @dev Mapping to check if an address is authorized to deposit in this contract.
    mapping(address => bool) public canDeposit;

    /// @dev Mapping to check if a token is allowed to be a deposited token (other than beacon ETH and stETH).
    mapping(IERC20 => bool) public isDepositToken;

    /// @dev Returns the deposited amount of an address for a given token.
    mapping(address => mapping(IERC20 => uint256)) public depositedAmount;

    /// @dev Mapping to record the Byzantine vaults.
    mapping(address => bool) public isByzantineVault;

    /// @dev If turned to true, public deposits will be allowed.
    bool public isPermissionlessDeposit = false;

    /* ============== MODIFIERS ============== */

    modifier onlyIfCanDeposit(
        address _address
    ) {
        if (!isPermissionlessDeposit) {
            require(canDeposit[_address], "ByzantineDeposit.onlyIfCanDeposit: address is not authorized to deposit");
        }
        _;
    }

    /* ============== CONSTRUCTOR ============== */

    /**
     * @notice Constructor for initializing the ByzantineDeposit contract
     * @param _pauserRegistry The address of the pauser registry contract
     * @param initPausedStatus The initial paused status flags
     * @param _initialOwner The address that will be set as the owner of this contract
     * @param _stETHToken The address of the stETH token contract
     * @param _wstETH The address of the wrapped stETH (wstETH) token contract
     */
    constructor(
        IPauserRegistry _pauserRegistry,
        uint256 initPausedStatus,
        address _initialOwner,
        IERC20 _stETHToken,
        IwstETH _wstETH
    ) Ownable(_initialOwner) {
        _initializePauser(_pauserRegistry, initPausedStatus);
        stETHToken = _stETHToken;
        wstETH = _wstETH;
    }

    /* ============== EXTERNAL FUNCTIONS ============== */

    /**
     * @notice Deposit beacon chain ETH into the contract
     * @dev Only callable by authorized addresses if permissionless deposit not allowed
     */
    function depositETH() external payable onlyWhenNotPaused(PAUSED_DEPOSITS) onlyIfCanDeposit(msg.sender) {
        require(msg.value > 0, "ByzantineDeposit.depositETH: no ETH sent");
        depositedAmount[msg.sender][beaconChainETHToken] += msg.value;
        emit Deposit(msg.sender, beaconChainETHToken, msg.value);
    }

    /**
     * @notice Deposit whitelisted ERC20 token into the contract
     * @param _token The ERC20 token to deposit
     * @param _amount The amount of the token to deposit
     * @dev If stETH is deposited, it will be wrapped to wstETH to avoid keeping rebasing tokens
     * @dev Caller first needs to approve the deposit contract to transfer the tokens
     * @dev Only callable by authorized addresses if permissionless deposit not allowed
     */
    function depositERC20(
        IERC20 _token,
        uint256 _amount
    ) external onlyWhenNotPaused(PAUSED_DEPOSITS) onlyIfCanDeposit(msg.sender) {
        require(
            _token == stETHToken || isDepositToken[_token],
            "ByzantineDeposit.depositERC20: token is not allowed to be deposited"
        );
        _token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 amount = _amount;
        if (_token == stETHToken) {
            stETHToken.approve(address(wstETH), _amount);
            amount = wstETH.wrap(_amount);
        }
        depositedAmount[msg.sender][_token] += amount;
        emit Deposit(msg.sender, _token, _amount);
    }

    /**
     * @notice Withdraw deposited tokens from the contract
     * @param _token The ERC20 token address to withdraw. 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for beacon chain ETH
     * @param _amount The amount of the token to withdraw. If stETH, `_amount` must be the amount of wstETH during the deposit(s)
     * @dev If stETH is withdrawn, it will be wstETH will be unwrapped to stETH
     */
    function withdraw(IERC20 _token, uint256 _amount) external onlyWhenNotPaused(PAUSED_WITHDRAWALS) nonReentrant {
        require(
            depositedAmount[msg.sender][_token] >= _amount,
            "ByzantineDeposit.withdraw: not enough deposited amount for token"
        );
        unchecked {
            // Overflow not possible because of previous check
            depositedAmount[msg.sender][_token] -= _amount;
        }
        uint256 amount = _amount;
        if (_token == beaconChainETHToken) {
            (bool success,) = msg.sender.call{value: amount}("");
            require(success, "ByzantineDeposit.withdraw: ETH transfer to withdrawer failed");
            emit Withdraw(msg.sender, _token, amount);
            return;
        } else if (_token == stETHToken) {
            amount = wstETH.unwrap(_amount);
        }
        _token.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, _token, amount);
    }

    /**
     * @notice Move deposited tokens to a Byzantine vault
     * @param _token The ERC20 token address to move. 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for beacon chain ETH
     * @param _vault The address of the Byzantine vault to move the tokens to.
     * @param _amount The amount of tokens to move. If stETH, `_amount` must be the amount of wstETH during the deposit(s)
     * @param _receiver The address who will receive the vault shares
     * @dev Revert if the Byzantine vault is not whitelisted
     */
    function moveToVault(
        IERC20 _token,
        address _vault,
        uint256 _amount,
        address _receiver
    ) external onlyWhenNotPaused(PAUSED_VAULTS_MOVES) nonReentrant {
        require(isByzantineVault[_vault], "ByzantineDeposit.moveToVault: vault is not recorded");
        require(
            depositedAmount[msg.sender][_token] >= _amount,
            "ByzantineDeposit.moveToVault: not enough deposited amount for token"
        );
        unchecked {
            // Overflow not possible because of previous check
            depositedAmount[msg.sender][_token] -= _amount;
        }
        uint256 amount = _amount;
        if (_token == beaconChainETHToken) {
            IERC7535(_vault).deposit{value: amount}(amount, _receiver);
            emit MoveToVault(msg.sender, _token, _vault, amount, _receiver);
            return;
        } else if (_token == stETHToken) {
            amount = wstETH.unwrap(_amount);
        }
        _token.approve(_vault, amount);
        IERC4626(_vault).deposit(amount, _receiver);
        emit MoveToVault(msg.sender, _token, _vault, amount, _receiver);
    }

    /* ============== ADMIN FUNCTIONS ============== */

    /**
     * @notice Sets whether an address is authorized to deposit in this contract
     * @param _address The address to set deposit permissions for
     * @param _canDeposit Boolean indicating if the address should be allowed to deposit or not
     * @dev Only callable by the owner
     */
    function setCanDeposit(address _address, bool _canDeposit) external onlyOwner {
        require(_address != address(0), "ByzantineDeposit.setCanDeposit: zero address input");
        canDeposit[_address] = _canDeposit;
        emit DepositorStatusChanged(_address, _canDeposit);
    }

    /**
     * @notice Adds a new token to the list of allowed deposit tokens (other than beacon ETH and stETH).
     * @param _token The ERC20 token contract address to add as an allowed deposit token
     * @dev Only callable by the owner
     * @dev /!\ rebasing tokens and exotic ERC20 tokens are not allowed /!\
     */
    function addDepositToken(
        IERC20 _token
    ) external onlyOwner {
        require(
            (_token != beaconChainETHToken) && (_token != stETHToken),
            "ByzantineDeposit.addDepositToken: beaconChainETH or stETH cannot be added"
        );
        isDepositToken[_token] = true;
        emit DepositTokenAdded(_token);
    }

    /**
     * @notice Change the permissionless deposit status
     * @param _permissionlessDeposit If set to true, public deposits will be allowed: anyone can deposit
     * @dev Only callable by the owner
     */
    function setPermissionlessDeposit(
        bool _permissionlessDeposit
    ) external onlyOwner {
        isPermissionlessDeposit = _permissionlessDeposit;
        emit PermissionlessDepositSet(_permissionlessDeposit);
    }

    /**
     * @notice Record Byzantine Vaults to allow moving tokens to them
     * @param _vaults The addresses of the Byzantine vaults to record / whitelist
     * @dev Only callable by the owner
     * @dev Once a vault has been recorded / whitelisted, it cannot be unrecorded / unwhitelisted. Stay vigilant.
     */
    function recordByzantineVaults(
        address[] calldata _vaults
    ) external onlyOwner {
        for (uint256 i = 0; i < _vaults.length;) {
            isByzantineVault[_vaults[i]] = true;
            unchecked {
                ++i;
            }
        }
    }
}
