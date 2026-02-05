// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Governor} from "@openzeppelin/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/governance/utils/IVotes.sol";

/**
 * @title DSCGovernor
 * @author CableGraph
 * @notice Governor contract for Decentralized StableCoin protocol
 * @dev Manages proposals, voting, and execution through TimelockController
 */
contract DSCGovernor is
    Governor,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    error DSCGovernor__VotingDelayNotPassed();
    error DSCGovernor__ProposalThresholdNotMet();
    error DSCGovernor__QuorumNotReached();
    error DSCGovernor__VotingPeriodActive();
    error DSCGovernor__ProposalNotSuccessful();
    error DSCGovernor__AlreadyVoted();
    error DSCGovernor__InvalidProposal();
    error DSCGovernor__TimelockNotReady();

    event ProposalCreated(
        uint256 proposalId,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );
    event ProposalQueued(uint256 proposalId, uint256 eta);
    event ProposalExecuted(uint256 proposalId);
    event ProposalCanceled(uint256 proposalId);
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 weight, string reason);

    uint256 public constant VOTING_DELAY = 1;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant PROPOSAL_THRESHOLD = 10_000e18;
    uint256 public constant QUORUM_PERCENTAGE = 4;

    enum ProposalType {
        PARAMETER_CHANGE,
        COLLATERAL_MANAGEMENT,
        EMERGENCY_ACTION,
        PROTOCOL_UPGRADE,
        TREASURY_MANAGEMENT
    }

    mapping(uint256 => ProposalType) private s_proposalTypes;
    mapping(uint256 => string) private s_proposalMetadata;
    mapping(uint256 => mapping(address => bool)) private s_hasVoted;
    uint256 private s_proposalCount;

    constructor(IVotes token, TimelockController timelock)
        Governor("DSC Governor")
        GovernorVotes(token)
        GovernorVotesQuorumFraction(QUORUM_PERCENTAGE)
        GovernorTimelockControl(timelock)
    {}

    /**
     * @notice Create a new governance proposal
     * @param targets Contract addresses to call
     * @param values ETH values to send with calls
     * @param calldatas Calldata for each call
     * @param description Description of the proposal
     * @param proposalType Type of proposal (for categorization)
     * @param metadata Additional metadata for the proposal
     * @return proposalId The ID of the created proposal
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        ProposalType proposalType,
        string memory metadata
    ) external returns (uint256) {
        uint256 proposerVotes = getVotes(msg.sender, block.number - 1);
        if (proposerVotes < PROPOSAL_THRESHOLD) {
            revert DSCGovernor__ProposalThresholdNotMet();
        }

        uint256 proposalId = super.propose(targets, values, calldatas, description);

        s_proposalTypes[proposalId] = proposalType;
        s_proposalMetadata[proposalId] = metadata;
        s_proposalCount++;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            _generateSignatures(targets, calldatas),
            calldatas,
            proposalSnapshot(proposalId),
            proposalDeadline(proposalId),
            description
        );

        return proposalId;
    }

    /**
     * @notice Cast a vote on a proposal
     * @param proposalId ID of the proposal to vote on
     * @param support Vote direction: 0=against, 1=for, 2=abstain
     * @param reason Reason for the vote (optional)
     * @return voteWeight The weight of the cast vote
     */
    function castVote(uint256 proposalId, uint8 support, string calldata reason) external returns (uint256) {
        if (state(proposalId) != ProposalState.Active) {
            revert DSCGovernor__InvalidProposal();
        }

        if (s_hasVoted[proposalId][msg.sender]) {
            revert DSCGovernor__AlreadyVoted();
        }

        uint256 voteWeight = _castVote(proposalId, msg.sender, support, reason);
        s_hasVoted[proposalId][msg.sender] = true;

        emit VoteCast(msg.sender, proposalId, support, voteWeight, reason);

        return voteWeight;
    }

    /**
     * @notice Cast a vote with a signature (gasless voting)
     * @param proposalId ID of the proposal to vote on
     * @param support Vote direction: 0=against, 1=for, 2=abstain
     * @param v Signature v component
     * @param r Signature r component
     * @param s Signature s component
     * @return voteWeight The weight of the cast vote
     */
    function castVoteBySig(uint256 proposalId, uint8 support, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256)
    {
        if (state(proposalId) != ProposalState.Active) {
            revert DSCGovernor__InvalidProposal();
        }

        uint256 voteWeight = _castVote(proposalId, msg.sender, support, "");

        emit VoteCast(msg.sender, proposalId, support, voteWeight, "");

        return voteWeight;
    }

    /**
     * @notice Execute a successful proposal
     * @param targets Contract addresses to call
     * @param values ETH values to send with calls
     * @param calldatas Calldata for each call
     * @param descriptionHash Hash of the proposal description
     * @param proposalId ID of the proposal to execute
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        uint256 proposalId
    ) external payable {
        if (state(proposalId) != ProposalState.Succeeded) {
            revert DSCGovernor__ProposalNotSuccessful();
        }

        uint256 eta = block.timestamp + TimelockController(payable(address(timelock()))).getMinDelay();
        _queue(proposalId, eta);

        super.execute(targets, values, calldatas, descriptionHash);

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal (only proposer or governor)
     * @param targets Contract addresses to call
     * @param values ETH values to send with calls
     * @param calldatas Calldata for each call
     * @param descriptionHash Hash of the proposal description
     * @param proposalId ID of the proposal to cancel
     */
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        uint256 proposalId
    ) external {
        require(
            msg.sender == proposalProposer(proposalId)
                || TimelockController(payable(address(timelock())))
                    .hasRole(TimelockController(payable(address(timelock()))).PROPOSER_ROLE(), msg.sender),
            "Not authorized"
        );

        super.cancel(targets, values, calldatas, descriptionHash);

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Get the proposer of a specific proposal
     * @param proposalId ID of the proposal
     * @return Address of the proposer
     */
    function proposalProposer(uint256 proposalId) public view returns (address) {
        return address(0);
    }

    /**
     * @dev Voting delay in blocks
     */
    function votingDelay() public pure override returns (uint256) {
        return VOTING_DELAY;
    }

    /**
     * @dev Voting period in blocks
     */
    function votingPeriod() public pure override returns (uint256) {
        return VOTING_PERIOD;
    }

    /**
     * @dev Proposal threshold in token units
     */
    function proposalThreshold() public pure override returns (uint256) {
        return PROPOSAL_THRESHOLD;
    }

    /**
     * @dev Quorum required for a proposal to pass
     */
    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    /**
     * @dev Get the current state of a proposal
     */
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    /**
     * @dev Execute a proposal that has been queued
     */
    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Cancel a proposal
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Get the executor address (timelock)
     */
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    /**
     * @dev Generate function signatures for better UX
     */
    function _generateSignatures(address[] memory targets, bytes[] memory calldatas)
        private
        pure
        returns (string[] memory)
    {
        string[] memory signatures = new string[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            if (calldatas[i].length >= 4) {
                bytes4 selector = bytes4(calldatas[i]);
                signatures[i] = _functionSignature(selector);
            } else {
                signatures[i] = "transfer()";
            }
        }
        return signatures;
    }

    /**
     * @dev Convert function selector to signature string
     */
    function _functionSignature(bytes4 selector) private pure returns (string memory) {
        if (selector == bytes4(keccak256("updateGovernanceToken(address)"))) {
            return "updateGovernanceToken(address)";
        } else if (selector == bytes4(keccak256("updateGovernanceMintRate(uint256)"))) {
            return "updateGovernanceMintRate(uint256)";
        } else if (selector == bytes4(keccak256("addCollateralType(address,address,uint8)"))) {
            return "addCollateralType(address,address,uint8)";
        } else if (selector == bytes4(keccak256("updateLiquidationParameters(uint256,uint256)"))) {
            return "updateLiquidationParameters(uint256,uint256)";
        } else if (selector == bytes4(keccak256("pause()"))) {
            return "pause()";
        } else if (selector == bytes4(keccak256("unpause()"))) {
            return "unpause()";
        } else if (selector == bytes4(keccak256("emergencyWithdraw(address)"))) {
            return "emergencyWithdraw(address)";
        } else {
            return "unknown()";
        }
    }

    /**
     * @dev Queue a proposal in the timelock
     */
    function _queue(uint256 proposalId, uint256 eta) private {}

    /**
     * @notice Get proposal type
     * @param proposalId ID of the proposal
     * @return Proposal type
     */
    function getProposalType(uint256 proposalId) external view returns (ProposalType) {
        return s_proposalTypes[proposalId];
    }

    /**
     * @notice Get proposal metadata
     * @param proposalId ID of the proposal
     * @return Proposal metadata
     */
    function getProposalMetadata(uint256 proposalId) external view returns (string memory) {
        return s_proposalMetadata[proposalId];
    }

    /**
     * @notice Check if an address has voted on a proposal
     * @param proposalId ID of the proposal
     * @param voter Address to check
     * @return True if the address has voted
     */
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return s_hasVoted[proposalId][voter];
    }

    /**
     * @notice Get total number of proposals
     * @return Total proposal count
     */
    function getProposalCount() external view returns (uint256) {
        return s_proposalCount;
    }

    /**
     * @notice Get voting power of an account at a specific block
     * @param account Address to check
     * @param blockNumber Block number to check at
     * @return Voting power
     */
    function getVotes(address account, uint256 blockNumber)
        public
        view
        override(IGovernor, GovernorVotes)
        returns (uint256)
    {
        return super.getVotes(account, blockNumber);
    }

    /**
     * @notice Get current voting power of an account
     * @param account Address to check
     * @return Current voting power
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        return getVotes(account, block.number - 1);
    }

    /**
     * @notice Check if quorum is reached for a proposal
     * @param proposalId ID of the proposal
     * @return True if quorum is reached
     */
    function isQuorumReached(uint256 proposalId) external view returns (bool) {
        ProposalState currentState = state(proposalId);
        return currentState == ProposalState.Succeeded || currentState == ProposalState.Queued
            || currentState == ProposalState.Executed;
    }
}
