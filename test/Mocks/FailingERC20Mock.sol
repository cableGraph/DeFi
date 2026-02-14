// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @notice A mock ERC20 token that always fails on transfer()
contract FailingERC20Mock is ERC20 {
    constructor() ERC20("FailToken", "FAIL") {}

    /// Override transfer to always fail
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    /// Allow minting for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
