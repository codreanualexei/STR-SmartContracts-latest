// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";



/**
 * @title RoyaltySplitter
 * @notice Делит входящие средства между creator и treasury по bps. Pull-платежи.
 * @dev Инициализируется один раз через init(). Админские действия доступны держателю DEFAULT_ADMIN_ROLE.
 */


contract RoyaltySplitter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Получатели и доли (в bps, 10000 = 100%)
    address public creator;
    address public treasury;
    uint16 public creatorBps;
    uint16 public treasuryBps;

    bool private _initialized;

    // Накопленные балансы для pull-withdraw
    mapping(address => uint256) public ethBalance;                        // получатель => сумма (MATIC)
    mapping(address => mapping(address => uint256)) public erc20Balance;  // token => получатель => сумма

    address[] private _trackedTokens;
    mapping(address => bool) private _isTrackedToken;

    // События
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
     * @notice Однократная инициализация. Устанавливает получателей и доли.
     * @dev Выдаёт DEFAULT_ADMIN_ROLE msg.sender'у.
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
     * @notice Обновить пропорции распределения (в bps). Только админ.
     */
    function setSplits(uint16 _creatorBps, uint16 _treasuryBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_initialized, "not init");
        require(_creatorBps + _treasuryBps == 10000, "split!=10000");
        creatorBps = _creatorBps;
        treasuryBps = _treasuryBps;
        emit SplitsUpdated(_creatorBps, _treasuryBps);
    }

    /**
     * @notice Приём нативного токена (MATIC). Делит и учитывает на балансах получателей.
     */
    receive() external payable {
        _collectNative(msg.value);
    }

    fallback() external payable {
        _collectNative(msg.value);
    }

    /**
     * @notice Приём ERC-20. Делит и учитывает на балансах получателей.
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
     * @notice Обновляет адрес создателя и переносит накопленные средства.
     *         Может вызвать текущий создатель либо админ (фабрика/DAO).
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
     * @notice Обновляет адрес казначейства и переносит накопленные средства.
     *         Доступно текущему казначейству или админам (фабрика/DAO).
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
     * @notice Выводит накопленный MATIC для msg.sender.
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
     * @notice Выводит накопленный ERC-20 для msg.sender.
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
