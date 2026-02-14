// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IGovernanceToken {
    function mintForDSC(address to, uint256 dscAmount) external returns (uint256);
    function burnFrom(address from, uint256 amount) external;
    function getDscEngine() external view returns (address);
    function getVotes(address account) external view returns (uint256);
    function delegate(address delegatee) external;
}
