// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "./permissions/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
 * @title ByzantineDeposit contract to allow early liquidity provider to deposit on the Byzantine protocol
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
    event Withdraw(address indexed sender, IERC20 token, uint256 amount, address receiver);
    event MoveToVault(address indexed owner, IERC20 token, address vault, uint256 amount, address receiver);
    event DepositorStatusChanged(address indexed depositor, bool canDeposit);
    event DepositTokenAdded(IERC20 token);
    event DepositTokenRemoved(IERC20 token);
    event ByzantineVaultRecorded(address vault);
    event ByzantineVaultDelisted(address vault);
    event PermissionlessDepositSet(bool permissionlessDeposit);

    /* ============== CONSTANTS + IMMUTABLES ============== */

    /// @dev Index for flag that pauses deposits when set
    uint8 internal constant PAUSED_DEPOSITS = 0;

    /// @dev Index for flag that pauses Byzantine vaults moves when set.
    uint8 internal constant PAUSED_VAULTS_MOVES = 1;

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
    bool public isPermissionlessDeposit;

    /* ============== MODIFIERS ============== */

    modifier onlyIfCanDeposit(
        address _address
    ) {
        if (!isPermissionlessDeposit) {
            if (!canDeposit[_address]) revert NotAuthorizedToDeposit(_address);
        }
        _;
    }

    /* ============== CONSTRUCTOR ============== */

    /**
     * @notice Constructor for initializing the ByzantineDeposit contract
     * @notice By default, the deposit of ETH, stETH and wstETH is allowed
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
        isDepositToken[beaconChainETHToken] = true;
        isDepositToken[stETHToken] = true;
        isDepositToken[wstETH] = true;
    }

    /* ============== EXTERNAL FUNCTIONS ============== */

    /**
     * @notice Deposit beacon chain ETH into the contract
     * @dev Only callable by authorized addresses if permissionless deposit not allowed
     */
    function depositETH() external payable onlyWhenNotPaused(PAUSED_DEPOSITS) onlyIfCanDeposit(msg.sender) {
        if (!isDepositToken[beaconChainETHToken]) revert NotAllowedDepositToken(beaconChainETHToken);
        if (msg.value == 0) revert ZeroETHSent();
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
        if (!isDepositToken[_token]) revert NotAllowedDepositToken(_token);
        _token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 amount = _amount;
        if (_token == stETHToken) {
            stETHToken.forceApprove(address(wstETH), _amount);
            amount = wstETH.wrap(_amount);
        }
        depositedAmount[msg.sender][_token] += amount;
        emit Deposit(msg.sender, _token, _amount);
    }

    /**
     * @notice Withdraw deposited tokens from the contract
     * @param _token The ERC20 token address to withdraw. 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for beacon chain ETH
     * @param _amount The amount of the token to withdraw. If stETH, `_amount` must be the amount of wstETH during the deposit(s)
     * @param _receiver The address who will receive the withdrawn tokens
     * @dev If stETH is withdrawn, it will be wstETH will be unwrapped to stETH
     */
    function withdraw(IERC20 _token, uint256 _amount, address _receiver) external nonReentrant {
        if (depositedAmount[msg.sender][_token] < _amount) revert InsufficientDepositedBalance(msg.sender, _token);
        unchecked {
            // Overflow not possible because of previous check
            depositedAmount[msg.sender][_token] -= _amount;
        }

        if (_token == beaconChainETHToken) {
            if (_receiver == address(0)) revert ReceiverIsZeroAddress();
            (bool success,) = _receiver.call{value: _amount}("");
            if (!success) revert ETHTransferFailed();
            emit Withdraw(msg.sender, _token, _amount, _receiver);
            return;
        } else if (_token == stETHToken) {
            _amount = wstETH.unwrap(_amount);
        }
        _token.safeTransfer(_receiver, _amount);
        emit Withdraw(msg.sender, _token, _amount, _receiver);
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
        address _receiver,
        uint256 _minSharesOut
    ) external onlyWhenNotPaused(PAUSED_VAULTS_MOVES) nonReentrant {
        if (!canDeposit[msg.sender]) revert NotAuthorizedToMoveFunds(msg.sender);
        if (!isByzantineVault[_vault]) revert NotAllowedVault(_vault);
        if (address(_token) != IERC4626(_vault).asset()) revert MismatchingAssets();
        if (depositedAmount[msg.sender][_token] < _amount) revert InsufficientDepositedBalance(msg.sender, _token);
        if (_receiver == address(0)) revert ReceiverIsZeroAddress();
        unchecked {
            // Overflow not possible because of previous check
            depositedAmount[msg.sender][_token] -= _amount;
        }

        uint256 sharesBefore;
        uint256 sharesAfter;
        if (_token == beaconChainETHToken) {
            sharesBefore = IERC7535(_vault).balanceOf(_receiver);
            IERC7535(_vault).deposit{value: _amount}(_amount, _receiver);
            sharesAfter = IERC7535(_vault).balanceOf(_receiver);
        } else {
            if (_token == stETHToken) {
                _amount = wstETH.unwrap(_amount);
            }
            _token.forceApprove(_vault, _amount);
            sharesBefore = IERC4626(_vault).balanceOf(_receiver);
            IERC4626(_vault).deposit(_amount, _receiver);
            sharesAfter = IERC4626(_vault).balanceOf(_receiver);
        }

        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived < _minSharesOut) revert InsufficientSharesReceived();
        emit MoveToVault(msg.sender, _token, _vault, _amount, _receiver);
    }

    /* ============== ADMIN FUNCTIONS ============== */

    /**
     * @notice Sets whether some addresses are authorized to deposit in this contract
     * @param _addr The addresses to set deposit permissions for
     * @param _canDeposit Boolean indicating if the addresses should be allowed to deposit or not
     * @dev Only callable by the owner
     */
    function setCanDeposit(address[] calldata _addr, bool _canDeposit) external onlyOwner {
        for (uint256 i; i < _addr.length;) {
            canDeposit[_addr[i]] = _canDeposit;
            emit DepositorStatusChanged(_addr[i], _canDeposit);
            unchecked {
                ++i;
            }
        }
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
        isDepositToken[_token] = true;
        emit DepositTokenAdded(_token);
    }

    /**
     * @notice Remove a token from the list of allowed deposit tokens
     * @param _token The ERC20 token contract address to remove from the allowed deposit tokens
     * @dev Only callable by the owner
     */
    function removeDepositToken(
        IERC20 _token
    ) external onlyOwner {
        isDepositToken[_token] = false;
        emit DepositTokenRemoved(_token);
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
        for (uint256 i; i < _vaults.length;) {
            isByzantineVault[_vaults[i]] = true;
            emit ByzantineVaultRecorded(_vaults[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Delist a Byzantine vault in case the whitelisting was made in error
     * @param _vault The address of the Byzantine vault to delist
     * @dev Only callable by the owner
     */
    function delistByzantineVault(
        address _vault
    ) external onlyOwner {
        isByzantineVault[_vault] = false;
        emit ByzantineVaultDelisted(_vault);
    }

    /* ============== CUSTOM ERRORS ============== */

    error NotAuthorizedToDeposit(address sender);
    error NotAuthorizedToMoveFunds(address sender);
    error NotAllowedDepositToken(IERC20 token);
    error NotAllowedVault(address vault);
    error InsufficientDepositedBalance(address sender, IERC20 token);
    error InsufficientSharesReceived();
    error MismatchingAssets();
    error ZeroETHSent();
    error ETHTransferFailed();
    error ReceiverIsZeroAddress();
}
