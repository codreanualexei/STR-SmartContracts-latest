// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IRoyaltySplitter {
    function init(address creator, address treasury, uint16 creatorBps, uint16 treasuryBps) external;
}

/**
 * @title RoyaltySplitterFactory
 * @notice Создаёт минимальные клоны RoyaltySplitter и вызывает init().
 *         Используется NFT-контрактом при минте для установки per-token роялти-получателя.
 */
contract RoyaltySplitterFactory is AccessControl {
    using Clones for address;

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    address public immutable implementation; // адрес заранее задеплоенного RoyaltySplitter (реализация)

    event SplitterCreated(
        address indexed splitter,
        address indexed creator,
        address indexed treasury,
        uint16 creatorBps,
        uint16 treasuryBps
    );

    constructor(address splitterImplementation) {
        require(splitterImplementation != address(0), "impl=0");
        implementation = splitterImplementation;
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Создаёт клон сплиттера и инициализирует его.
     * @param creator адрес создателя NFT
     * @param treasury адрес казначейства (платформы)
     * @param creatorBps доля создателя (из 10000)
     * @param treasuryBps доля казны (из 10000). Сумма должна быть 10000.
     */
    function createSplitter(
        address creator,
        address treasury,
        uint16 creatorBps,
        uint16 treasuryBps
    ) external returns (address splitter) {
        require(creator != address(0) && treasury != address(0), "zero addr");
        require(uint256(creatorBps) + uint256(treasuryBps) == 10000, "split!=10000");

        splitter = implementation.clone(); // минимальный прокси EIP-1167
        IRoyaltySplitter(splitter).init(creator, treasury, creatorBps, treasuryBps);

        emit SplitterCreated(splitter, creator, treasury, creatorBps, treasuryBps);
    }
}
