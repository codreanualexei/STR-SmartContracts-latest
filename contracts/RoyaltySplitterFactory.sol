// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IRoyaltySplitter {
    function init(address creator, address treasury, uint16 creatorBps, uint16 treasuryBps) external;
    function updateTreasury(address newTreasury) external;
}

/**
 * @title RoyaltySplitterFactory
 * @notice Deploys minimal proxy clones of RoyaltySplitter and runs init().
 *         Used by the NFT contract at mint time to configure per-token royalty recipients.
 */
contract RoyaltySplitterFactory is AccessControl {
    using Clones for address;

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    address public immutable implementation; // address of the pre-deployed RoyaltySplitter implementation

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
     * @notice Creates a splitter clone and initializes it.
     * @param creator address of the NFT creator
     * @param treasury address of the platform treasury
     * @param creatorBps creator share in basis points (out of 10000)
     * @param treasuryBps treasury share in basis points (out of 10000). Sum must equal 10000.
     */
    function createSplitter(
        address creator,
        address treasury,
        uint16 creatorBps,
        uint16 treasuryBps
    ) external returns (address splitter) {
        require(creator != address(0) && treasury != address(0), "zero addr");
        require(uint256(creatorBps) + uint256(treasuryBps) == 10000, "split!=10000");

        splitter = implementation.clone(); // minimal proxy (EIP-1167)
        IRoyaltySplitter(splitter).init(creator, treasury, creatorBps, treasuryBps);

        emit SplitterCreated(splitter, creator, treasury, creatorBps, treasuryBps);
    }

    /**
     * @notice Updates the treasury address on an existing splitter.
     *         Callable only by factory admins.
     */
    function updateSplitterTreasury(address splitter, address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(splitter != address(0), "splitter=0");
        IRoyaltySplitter(splitter).updateTreasury(newTreasury);
    }

}
