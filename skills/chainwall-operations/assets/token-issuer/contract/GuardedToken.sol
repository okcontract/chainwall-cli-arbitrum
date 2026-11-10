// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Demo mintable token for the token-issuer setup. Not audited. Replace with
/// your own token address and ABI for real use. Minimal ERC-20 with an owner
/// who can mint, burn and pause transfers.
contract GuardedToken {
    string public constant name = "Guarded Demo Token";
    string public constant symbol = "GDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public owner;
    bool public paused;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Paused(bool paused);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error TransfersPaused();
    error Insufficient();

    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    function mint(address to, uint256 amount) external onlyOwner { totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount); }
    function burn(address from, uint256 amount) external onlyOwner { if (balanceOf[from] < amount) revert Insufficient(); balanceOf[from] -= amount; totalSupply -= amount; emit Transfer(from, address(0), amount); }
    function setPaused(bool p) external onlyOwner { paused = p; emit Paused(p); }
    function transferOwnership(address to) external onlyOwner { emit OwnershipTransferred(owner, to); owner = to; }

    function transfer(address to, uint256 amount) external returns (bool) { return _move(msg.sender, to, amount); }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender]; if (a < amount) revert Insufficient(); allowance[from][msg.sender] = a - amount; return _move(from, to, amount);
    }
    function _move(address from, address to, uint256 amount) private returns (bool) {
        if (paused) revert TransfersPaused(); if (balanceOf[from] < amount) revert Insufficient();
        balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); return true;
    }
}
