// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IGovernanceControl {
    function executeProposal(address target, uint256 value, bytes calldata data, bytes32 descriptionHash) external;
    function isProposalExecuted(bytes32 proposalId) external view returns (bool);
}
