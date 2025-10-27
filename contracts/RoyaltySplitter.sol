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

    // События
    event Initialized(address indexed creator, address indexed treasury, uint16 creatorBps, uint16 treasuryBps);
    event SplitsUpdated(uint16 creatorBps, uint16 treasuryBps);
    event Received(address indexed from, uint256 amount);
    event TokenReceived(address indexed token, address indexed from, uint256 amount);
    event Withdraw(address indexed to, uint256 amount);
    event WithdrawToken(address indexed token, address indexed to, uint256 amount);

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
        require(_initialized, "not init");
        if (msg.value == 0) return;
        uint256 toCreator = (msg.value * creatorBps) / 10000;
        uint256 toTreasury = msg.value - toCreator;
        ethBalance[creator] += toCreator;
        ethBalance[treasury] += toTreasury;
        emit Received(msg.sender, msg.value);
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

        emit TokenReceived(token, msg.sender, amount);
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
}
