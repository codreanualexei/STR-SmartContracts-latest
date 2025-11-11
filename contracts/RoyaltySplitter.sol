// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";



/**
 * @title RoyaltySplitter
 * @notice Splits incoming funds between the creator and the treasury using basis points. Pull-withdraw model.
 * @dev Initialized once via init(). Administrative actions are gated by DEFAULT_ADMIN_ROLE.
 */


contract RoyaltySplitter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Recipients and shares (basis points, 10000 = 100%)
    address public creator;
    address public treasury;
    uint16 public creatorBps;
    uint16 public treasuryBps;

    bool private _initialized;

    // Accumulated balances available for pull-withdraw
    mapping(address => uint256) public ethBalance;                        // recipient => amount (native token)
    mapping(address => mapping(address => uint256)) public erc20Balance;  // token => recipient => amount

    address[] private _trackedTokens;
    mapping(address => bool) private _isTrackedToken;

    // Events
    event Initialized(address indexed creator, address indexed treasury, uint16 creatorBps, uint16 treasuryBps);
    event SplitsUpdated(uint16 creatorBps, uint16 treasuryBps);
    event Received(address indexed from, uint256 amount);
    event TokenReceived(address indexed token, address indexed from, uint256 amount);
    event Withdraw(address indexed to, uint256 amount);
    event WithdrawToken(address indexed token, address indexed to, uint256 amount);
    event CreatorUpdated(address indexed oldCreator, address indexed newCreator);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    modifier onlyOnce() {
        require(!_initialized, "already initialized");
        _;
    }

    /**
     * @notice One-time initialization. Sets recipients and their respective shares.
     * @dev Grants DEFAULT_ADMIN_ROLE to msg.sender.
     */
    function init(
        address _creator,
        address _treasury,
        uint16 _creatorBps,
        uint16 _treasuryBps
    ) external onlyOnce {
        require(_creator != address(0) && _treasury != address(0), "zero address");
        require(_creatorBps + _treasuryBps == 10000, "split!=10000");

        creator = _creator;
        treasury = _treasury;
        creatorBps = _creatorBps;
        treasuryBps = _treasuryBps;

        _initialized = true;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        emit Initialized(_creator, _treasury, _creatorBps, _treasuryBps);
    }

    /**
     * @notice Update the split proportions (in basis points). Admin-only.
     */
    function setSplits(uint16 _creatorBps, uint16 _treasuryBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_initialized, "not init");
        require(_creatorBps + _treasuryBps == 10000, "split!=10000");
        creatorBps = _creatorBps;
        treasuryBps = _treasuryBps;
        emit SplitsUpdated(_creatorBps, _treasuryBps);
    }

    /**
     * @notice Receives native tokens and proportions them to recipient balances.
     */
    receive() external payable {
        _collectNative(msg.value);
    }

    fallback() external payable {
        _collectNative(msg.value);
    }

    /**
     * @notice Receives ERC-20 tokens and proportions them to recipient balances.
     */
    function depositToken(address token, uint256 amount) external nonReentrant {
        require(_initialized, "not init");
        require(token != address(0), "token=0");
        require(amount > 0, "amount=0");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 toCreator = (amount * creatorBps) / 10000;
        uint256 toTreasury = amount - toCreator;

        erc20Balance[token][creator] += toCreator;
        erc20Balance[token][treasury] += toTreasury;
        _trackToken(token);

        emit TokenReceived(token, msg.sender, amount);
    }

    /**
     * @notice Updates the creator address and migrates any accrued balances.
     *         Callable only by the current creator.
     */
    function updateCreator(address newCreator) external {
        require(_initialized, "not init");
        require(newCreator != address(0), "creator=0");
        require(msg.sender == creator, "only creator");

        address oldCreator = creator;
        require(oldCreator != newCreator, "same creator");

        creator = newCreator;
        _moveEthBalance(oldCreator, newCreator);
        _moveTokenBalances(oldCreator, newCreator);

        emit CreatorUpdated(oldCreator, newCreator);
    }

    /**
     * @notice Updates the treasury address and migrates any accrued balances.
     *         Callable by the current treasury address or contract admins.
     */
    function updateTreasury(address newTreasury) external {
        require(_initialized, "not init");
        require(newTreasury != address(0), "treasury=0");
        require(msg.sender == treasury || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "unauthorized");

        address oldTreasury = treasury;
        require(oldTreasury != newTreasury, "same treasury");

        treasury = newTreasury;
        _moveEthBalance(oldTreasury, newTreasury);
        _moveTokenBalances(oldTreasury, newTreasury);

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Withdraw accumulated native tokens for msg.sender.
     */
    function withdraw() external nonReentrant {
        uint256 bal = ethBalance[msg.sender];
        require(bal > 0, "no funds");
        ethBalance[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{ value: bal }("");
        require(ok, "transfer failed");
        emit Withdraw(msg.sender, bal);
    }

    /**
     * @notice Withdraw accumulated ERC-20 tokens for msg.sender.
     */
    function withdrawToken(address token) external nonReentrant {
        uint256 bal = erc20Balance[token][msg.sender];
        require(bal > 0, "no funds");
        erc20Balance[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, bal);
        emit WithdrawToken(token, msg.sender, bal);
    }

    function _collectNative(uint256 amount) private {
        require(_initialized, "not init");
        if (amount == 0) return;
        uint256 toCreator = (amount * creatorBps) / 10000;
        uint256 toTreasury = amount - toCreator;
        ethBalance[creator] += toCreator;
        ethBalance[treasury] += toTreasury;
        emit Received(msg.sender, amount);
    }

    function _trackToken(address token) private {
        if (!_isTrackedToken[token]) {
            _isTrackedToken[token] = true;
            _trackedTokens.push(token);
        }
    }

    function _moveEthBalance(address from, address to) private {
        uint256 bal = ethBalance[from];
        if (bal > 0) {
            ethBalance[from] = 0;
            ethBalance[to] += bal;
        }
    }

    function _moveTokenBalances(address from, address to) private {
        uint256 len = _trackedTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address token = _trackedTokens[i];
            uint256 bal = erc20Balance[token][from];
            if (bal > 0) {
                erc20Balance[token][from] = 0;
                erc20Balance[token][to] += bal;
            }
        }
    }
}
