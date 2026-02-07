// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Governor} from "@openzeppelin/governance/Governor.sol";
import {IGovernor} from "@openzeppelin/governance/IGovernor.sol";

import {
    GovernorSettings
} from "@openzeppelin/governance/extensions/GovernorSettings.sol";
import {
    GovernorVotes
} from "@openzeppelin/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/governance/extensions/GovernorVotesQuorumFraction.sol";
import {
    GovernorCountingSimple
} from "@openzeppelin/governance/extensions/GovernorCountingSimple.sol";
import {
    GovernorTimelockControl
} from "@openzeppelin/governance/extensions/GovernorTimelockControl.sol";
import {
    GovernorPreventLateQuorum
} from "@openzeppelin/governance/extensions/GovernorPreventLateQuorum.sol";

import {IVotes} from "@openzeppelin/governance/utils/IVotes.sol";
import {
    TimelockController
} from "@openzeppelin/governance/TimelockController.sol";

contract DSCGovernorClean is
    Governor,
    GovernorSettings,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorCountingSimple,
    GovernorTimelockControl,
    GovernorPreventLateQuorum
{
    constructor(
        IVotes token,
        TimelockController timelock
    )
        Governor("DSCGovernor")
        GovernorSettings(1 days, 3 days, 10_000 ether)
        GovernorVotes(token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(timelock)
        GovernorPreventLateQuorum(1 days)
    {}

    /*//////////////////////////////////////////////////////////////
                            REQUIRED OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function votingDelay()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(
        uint256 blockNumber
    )
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function state(
        uint256 proposalId
    )
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalDeadline(
        uint256 proposalId
    )
        public
        view
        override(IGovernor, Governor, GovernorPreventLateQuorum)
        returns (uint256)
    {
        return super.proposalDeadline(proposalId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                        DIAMOND RESOLUTION (MANDATORY)
    //////////////////////////////////////////////////////////////*/

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory params
    ) internal override(Governor, GovernorPreventLateQuorum) returns (uint256) {
        return super._castVote(proposalId, account, support, reason, params);
    }
}
