// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Demo target for the protocol-admin setup. Not audited. Replace with your
/// own contract address and ABI for real use.
contract GuardedParams {
    address public owner;
    uint256 public feeBps;
    address public oracle;

    event FeeSet(uint256 feeBps);
    event OracleSet(address oracle);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();

    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    /// Routine: bounded parameter change.
    function setFee(uint256 bps) external onlyOwner { feeBps = bps; emit FeeSet(bps); }

    /// Sensitive: changes a trust assumption.
    function setOracle(address o) external onlyOwner { oracle = o; emit OracleSet(o); }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferred(owner, to);
        owner = to;
    }
}
