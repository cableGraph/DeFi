// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import {
    ERC20Permit
} from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import {
    ERC20Burnable
} from "@openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

/**
 * @title DSCGovernanceToken
 * @author CableGraph
 * @notice ERC20 token with voting capabilities for the Decentralized StableCoin protocol.
 * This token grants holders governance rights over the protocol, including:
 * - Adding/removing collateral types
 * - Adjusting risk parameters
 * - Managing oracle systems
 * - Controlling protocol upgrades
 *
 * Features:
 * 1. Vote delegation (like Compound's COMP)
 * 2. Time-weighted voting (like MakerDAO's MKR)
 * 3. Emergency pause system
 * 4. Gradual token distribution
 * 5. Token locking for commitment
 *
 * Tokenomics:
 * - Total Supply: 1,000,000,000 DSCG
 * - Initial Distribution: 100,000,000 DSCG
 * - Governance controlled minting for future distribution
 * - Deflationary burning mechanism
 *
 * @dev Based on real-world benchmarks:
 * - Compound COMP: Delegated voting
 * - Uniswap UNI: Time-locked distribution, community treasury
 * - MakerDAO MKR: Governance-controlled parameters
 */
contract DSCGovernanceToken is
    ERC20,
    ERC20Permit,
    ERC20Votes,
    ERC20Burnable,
    Ownable2Step
{
    /////////////////
    //// ERRORS ////
    ///////////////
    error DSCGovernanceToken__InvalidAddress();
    error DSCGovernanceToken__ZeroAmount();
    error DSCGovernanceToken__MintingDisabled();
    error DSCGovernanceToken__DistributionLocked();
    error DSCGovernanceToken__TransferPaused();
    error DSCGovernanceToken__InsufficientLockTime();
    error DSCGovernanceToken__MaxSupplyExceeded();
    error DSCGovernanceToken__DelegationLocked();
    error DSCGovernanceToken__InvalidLockIndex();
    error DSCGovernanceToken__LockNotExpired();
    error DSCGovernanceToken__NothingToClaim();

    /////////////////
    //// EVENTS ////
    ///////////////
    event TokensMinted(address indexed to, uint256 amount, string purpose);
    event TokensBurned(address indexed from, uint256 amount);
    event DelegationChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );
    event TransferPaused(address indexed pauser, bool paused);
    event DistributionLocked(uint256 unlockTimestamp, uint256 lockedAmount);
    event EmergencyWithdrawal(
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );
    event TokensLocked(
        address indexed user,
        uint256 amount,
        uint256 unlockTime
    );
    event TokensUnlocked(address indexed user, uint256 amount);
    event VestingClaimed(address indexed user, uint256 amount);

    //////////////////////
    //// CONSTANTS //////
    ////////////////////
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1 billion tokens
    uint256 public constant INITIAL_SUPPLY = 100_000_000 ether; // 100 million initial
    uint256 public constant COMMUNITY_TREASURY_SUPPLY = 300_000_000 ether; // 30% for community
    uint256 public constant TEAM_SUPPLY = 150_000_000 ether; // 15% for team (4-year vesting)
    uint256 public constant INVESTOR_SUPPLY = 100_000_000 ether; // 10% for investors
    uint256 public constant ECOSYSTEM_SUPPLY = 350_000_000 ether; // 35% for ecosystem growth

    uint256 public constant MIN_LOCK_TIME = 7 days; // Minimum lock time for delegated tokens
    uint256 public constant VESTING_PERIOD = 4 * 365 days; // 4-year vesting for team/investors
    uint256 public constant DELEGATION_COOLDOWN = 7 days; // Cooldown between delegation changes

    //////////////////////
    //// STATE VARS /////
    ////////////////////
    struct TokenLock {
        uint256 amount;
        uint256 unlockTime;
    }

    struct DistributionSchedule {
        uint256 totalAllocated;
        uint256 claimedAmount;
        uint256 startTime;
        uint256 cliffPeriod;
        uint256 vestingPeriod;
    }

    address public immutable COMMUNITY_TREASURY;
    address public immutable TEAM_WALLET;
    address public immutable INVESTOR_WALLET;
    address public immutable ECOSYSTEM_FUND;

    mapping(address => DistributionSchedule) public distributionSchedules;
    mapping(address => TokenLock[]) public tokenLocks;
    mapping(address => uint256) public lastDelegationTime;

    bool public transfersPaused;
    bool public mintingEnabled = true;
    uint256 public totalLockedTokens;
    uint256 public totalDistributed;

    /////////////////
    //// MODIFIERS //
    /////////////////
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) revert DSCGovernanceToken__InvalidAddress();
        _;
    }

    modifier notZeroAmount(uint256 amount) {
        if (amount == 0) revert DSCGovernanceToken__ZeroAmount();
        _;
    }

    modifier whenTransfersNotPaused() {
        if (transfersPaused) revert DSCGovernanceToken__TransferPaused();
        _;
    }

    modifier whenMintingEnabled() {
        if (!mintingEnabled) revert DSCGovernanceToken__MintingDisabled();
        _;
    }

    modifier validLockIndex(address user, uint256 lockIndex) {
        if (lockIndex >= tokenLocks[user].length) {
            revert DSCGovernanceToken__InvalidLockIndex();
        }
        _;
    }

    //////////////////
    //// CONSTRUCTOR //
    /////////////////
    constructor(
        address communityTreasury,
        address teamWallet,
        address investorWallet,
        address ecosystemFund
    )
        ERC20("Decentralized StableCoin Governance", "DSCG")
        ERC20Permit("Decentralized StableCoin Governance")
    {
        if (
            communityTreasury == address(0) ||
            teamWallet == address(0) ||
            investorWallet == address(0) ||
            ecosystemFund == address(0)
        ) {
            revert DSCGovernanceToken__InvalidAddress();
        }

        COMMUNITY_TREASURY = communityTreasury;
        TEAM_WALLET = teamWallet;
        INVESTOR_WALLET = investorWallet;
        ECOSYSTEM_FUND = ecosystemFund;

        _mint(msg.sender, INITIAL_SUPPLY);

        _initializeDistributionSchedules();
    }

    //////////////////////////////
    //// EXTERNAL FUNCTIONS /////
    ////////////////////////////

    /**
     * @notice Mint new governance tokens (governance controlled)
     * @dev Only owner can mint, respecting max supply
     * @param to Address to receive minted tokens
     * @param amount Amount to mint
     * @param purpose Purpose of minting (for transparency)
     */
    function mint(
        address to,
        uint256 amount,
        string calldata purpose
    )
        external
        onlyOwner
        whenMintingEnabled
        notZeroAddress(to)
        notZeroAmount(amount)
    {
        if (totalSupply() + amount > MAX_SUPPLY) {
            revert DSCGovernanceToken__MaxSupplyExceeded();
        }

        _mint(to, amount);
        emit TokensMinted(to, amount, purpose);
    }

    /**
     * @notice Burn tokens from caller's balance
     * @param amount Amount to burn
     */
    function burn(uint256 amount) public override notZeroAmount(amount) {
        super.burn(amount);
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @notice Burn tokens from a specific account (with approval)
     * @param account Account to burn from
     * @param amount Amount to burn
     */
    function burnFrom(
        address account,
        uint256 amount
    ) public override notZeroAddress(account) notZeroAmount(amount) {
        super.burnFrom(account, amount);
        emit TokensBurned(account, amount);
    }

    /**
     * @notice Lock tokens for a period of time (for delegation commitment)
     * @param amount Amount to lock
     * @param lockTime Duration to lock (must be >= MIN_LOCK_TIME)
     */
    function lockTokens(
        uint256 amount,
        uint256 lockTime
    ) external notZeroAmount(amount) whenTransfersNotPaused {
        if (lockTime < MIN_LOCK_TIME) {
            revert DSCGovernanceToken__InsufficientLockTime();
        }

        _transfer(msg.sender, address(this), amount);

        tokenLocks[msg.sender].push(
            TokenLock({amount: amount, unlockTime: block.timestamp + lockTime})
        );

        totalLockedTokens += amount;

        emit TokensLocked(msg.sender, amount, block.timestamp + lockTime);
        emit DistributionLocked(block.timestamp + lockTime, amount);
    }

    /**
     * @notice Unlock tokens after lock period has expired
     * @param lockIndex Index of the lock to unlock
     */
    function unlockTokens(
        uint256 lockIndex
    ) external validLockIndex(msg.sender, lockIndex) {
        TokenLock storage lock = tokenLocks[msg.sender][lockIndex];

        if (block.timestamp < lock.unlockTime) {
            revert DSCGovernanceToken__LockNotExpired();
        }

        uint256 amount = lock.amount;

        uint256 lastIndex = tokenLocks[msg.sender].length - 1;
        if (lockIndex != lastIndex) {
            tokenLocks[msg.sender][lockIndex] = tokenLocks[msg.sender][
                lastIndex
            ];
        }
        tokenLocks[msg.sender].pop();

        totalLockedTokens -= amount;

        _transfer(address(this), msg.sender, amount);

        emit TokensUnlocked(msg.sender, amount);
    }

    /**
     * @notice Claim vested tokens from team/investor distributions
     */
    function claimVestedTokens() external {
        DistributionSchedule storage schedule = distributionSchedules[
            msg.sender
        ];

        if (schedule.totalAllocated == 0) {
            revert DSCGovernanceToken__NothingToClaim();
        }

        uint256 claimable = _calculateClaimableAmount(msg.sender);
        if (claimable == 0) {
            revert DSCGovernanceToken__NothingToClaim();
        }

        schedule.claimedAmount += claimable;
        _mint(msg.sender, claimable);

        totalDistributed += claimable;

        emit VestingClaimed(msg.sender, claimable);
    }

    /**
     * @notice Delegate voting power to another address
     * @dev Override with delegation lock mechanism
     * @param delegatee Address to delegate voting power to
     */
    function delegate(
        address delegatee
    ) public override notZeroAddress(delegatee) {
        if (
            lastDelegationTime[msg.sender] + DELEGATION_COOLDOWN >
            block.timestamp
        ) {
            revert DSCGovernanceToken__DelegationLocked();
        }

        address currentDelegate = delegates(msg.sender);
        super.delegate(delegatee);

        lastDelegationTime[msg.sender] = block.timestamp;
        emit DelegationChanged(msg.sender, currentDelegate, delegatee);
    }

    /**
     * @notice Delegate voting power by signature (EIP-712)
     * @param delegatee Address to delegate voting power to
     * @param nonce Nonce for signature
     * @param expiry Signature expiry timestamp
     * @param v Signature component
     * @param r Signature component
     * @param s Signature component
     */
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override notZeroAddress(delegatee) {
        super.delegateBySig(delegatee, nonce, expiry, v, r, s);
        lastDelegationTime[msg.sender] = block.timestamp;
    }

    /**
     * @notice Pause or unpause token transfers
     * @dev Only owner can call, typically used during emergencies
     * @param paused Whether to pause transfers
     */
    function setTransfersPaused(bool paused) external onlyOwner {
        transfersPaused = paused;
        emit TransferPaused(msg.sender, paused);
    }

    /**
     * @notice Enable or disable minting
     * @dev Only owner can call, typically disabled after initial distribution
     * @param enabled Whether minting is enabled
     */
    function setMintingEnabled(bool enabled) external onlyOwner {
        mintingEnabled = enabled;
    }

    /**
     * @notice Emergency withdrawal of locked tokens (owner only)
     * @dev Only for extreme emergencies, typically requires multisig approval
     * @param to Address to withdraw to
     * @param amount Amount to withdraw from contract balance
     */
    function emergencyWithdraw(
        address to,
        uint256 amount
    ) external onlyOwner notZeroAddress(to) notZeroAmount(amount) {
        require(
            balanceOf(address(this)) >= amount,
            "Insufficient contract balance"
        );

        _transfer(address(this), to, amount);
        emit EmergencyWithdrawal(to, amount, block.timestamp);
    }

    //////////////////////////
    //// VIEW FUNCTIONS /////
    ////////////////////////

    /**
     * @notice Calculate claimable vested tokens for an address
     * @param account Account to check
     * @return Claimable token amount
     */
    function calculateClaimableAmount(
        address account
    ) external view returns (uint256) {
        return _calculateClaimableAmount(account);
    }

    /**
     * @notice Get all active token locks for an account
     * @param account Account to check
     * @return locks Array of active token locks
     */
    function getTokenLocks(
        address account
    ) external view returns (TokenLock[] memory locks) {
        locks = tokenLocks[account];
    }

    /**
     * @notice Get total locked tokens for an account
     * @param account Account to check
     * @return Total locked token amount
     */
    function getTotalLockedTokens(
        address account
    ) external view returns (uint256) {
        uint256 total = 0;
        TokenLock[] storage locks = tokenLocks[account];

        for (uint256 i = 0; i < locks.length; i++) {
            total += locks[i].amount;
        }

        return total;
    }

    /**
     * @notice Get delegation information for an account
     * @param account Account to check
     * @return delegatee Current delegatee
     * @return delegationTime Last delegation time
     * @return canRedelegate Whether account can redelegate now
     */
    function getDelegationInfo(
        address account
    )
        external
        view
        returns (address delegatee, uint256 delegationTime, bool canRedelegate)
    {
        delegatee = delegates(account);
        delegationTime = lastDelegationTime[account];
        canRedelegate = block.timestamp >= delegationTime + DELEGATION_COOLDOWN;
    }

    /**
     * @notice Check if an account has enough voting power for proposals
     * @param account Account to check
     * @param requiredPower Required voting power
     * @return Whether account has sufficient power
     */
    function hasVotingPower(
        address account,
        uint256 requiredPower
    ) external view returns (bool) {
        return getVotes(account) >= requiredPower;
    }

    /**
     * @notice Get total unlocked (transferable) balance for an account
     * @param account Account to check
     * @return Unlocked token amount
     */
    function getUnlockedBalance(
        address account
    ) external view returns (uint256) {
        uint256 locked = _getTotalLockedTokens(account);
        uint256 total = balanceOf(account);

        if (total > locked) {
            return total - locked;
        }
        return 0;
    }

    /**
     * @notice Get effective voting power (excluding locked tokens)
     * @param account Account to check
     * @return Effective voting power
     */
    function getEffectiveVotes(
        address account
    ) external view returns (uint256) {
        uint256 locked = _getTotalLockedTokens(account);
        uint256 totalVotes = getVotes(account);

        if (totalVotes > locked) {
            return totalVotes - locked;
        }
        return 0;
    }

    //////////////////////////////////
    //// INTERNAL FUNCTIONS /////////
    ////////////////////////////////

    /**
     * @dev Initialize distribution schedules for team, investors, etc.
     */
    function _initializeDistributionSchedules() internal {
        distributionSchedules[TEAM_WALLET] = DistributionSchedule({
            totalAllocated: TEAM_SUPPLY,
            claimedAmount: 0,
            startTime: block.timestamp + 90 days,
            cliffPeriod: 365 days,
            vestingPeriod: VESTING_PERIOD
        });

        distributionSchedules[INVESTOR_WALLET] = DistributionSchedule({
            totalAllocated: INVESTOR_SUPPLY,
            claimedAmount: 0,
            startTime: block.timestamp + 90 days,
            cliffPeriod: 365 days,
            vestingPeriod: VESTING_PERIOD
        });

        distributionSchedules[ECOSYSTEM_FUND] = DistributionSchedule({
            totalAllocated: ECOSYSTEM_SUPPLY,
            claimedAmount: 0,
            startTime: block.timestamp,
            cliffPeriod: 0,
            vestingPeriod: 0
        });

        distributionSchedules[COMMUNITY_TREASURY] = DistributionSchedule({
            totalAllocated: COMMUNITY_TREASURY_SUPPLY,
            claimedAmount: 0,
            startTime: block.timestamp,
            cliffPeriod: 0,
            vestingPeriod: 0
        });
    }

    /**
     * @dev Calculate claimable vested amount for an account
     */
    function _calculateClaimableAmount(
        address account
    ) internal view returns (uint256) {
        DistributionSchedule storage schedule = distributionSchedules[account];

        if (schedule.totalAllocated == 0) {
            return 0;
        }

        if (block.timestamp < schedule.startTime + schedule.cliffPeriod) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp -
            (schedule.startTime + schedule.cliffPeriod);
        uint256 totalVestingTime = schedule.vestingPeriod;

        if (elapsedTime >= totalVestingTime) {
            return schedule.totalAllocated - schedule.claimedAmount;
        }

        uint256 vestedAmount = (schedule.totalAllocated * elapsedTime) /
            totalVestingTime;
        if (vestedAmount > schedule.claimedAmount) {
            return vestedAmount - schedule.claimedAmount;
        }

        return 0;
    }
    function _getTotalLockedTokens(
        address account
    ) internal view returns (uint256) {
        uint256 total = 0;
        TokenLock[] storage locks = tokenLocks[account];

        for (uint256 i = 0; i < locks.length; i++) {
            total += locks[i].amount;
        }

        return total;
    }

    //////////////////////////////////
    //// OVERRIDE FUNCTIONS /////////
    ////////////////////////////////

    /**
     * @dev Hook that is called before any transfer of tokens
     * Override to include pause functionality
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20) {
        if (from != address(0) && to != address(0) && transfersPaused) {
            revert DSCGovernanceToken__TransferPaused();
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Hook that is called after any transfer of tokens
     * Override to update voting power
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    /**
     * @dev Override mint function
     */
    function _mint(
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    /**
     * @dev Override burn function
     */
    function _burn(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }

    ////////////////////
    //// GETTERS //////
    //////////////////

    /**
     * @notice Get total distributed tokens
     * @return Total distributed tokens
     */
    function getTotalDistributed() external view returns (uint256) {
        return totalDistributed;
    }

    /**
     * @notice Get total locked tokens across all accounts
     * @return Total locked tokens
     */
    function getGlobalLockedTokens() external view returns (uint256) {
        return totalLockedTokens;
    }

    /**
     * @notice Check if transfers are currently paused
     * @return Whether transfers are paused
     */
    function isTransfersPaused() external view returns (bool) {
        return transfersPaused;
    }

    /**
     * @notice Check if minting is currently enabled
     * @return Whether minting is enabled
     */
    function isMintingEnabled() external view returns (bool) {
        return mintingEnabled;
    }

    /**
     * @notice Get distribution addresses
     * @return communityTreasury Community treasury address
     * @return teamWallet Team wallet address
     * @return investorWallet Investor wallet address
     * @return ecosystemFund Ecosystem fund address
     */
    function getDistributionAddresses()
        external
        view
        returns (
            address communityTreasury,
            address teamWallet,
            address investorWallet,
            address ecosystemFund
        )
    {
        return (
            COMMUNITY_TREASURY,
            TEAM_WALLET,
            INVESTOR_WALLET,
            ECOSYSTEM_FUND
        );
    }

    /**
     * @notice Get total supply minus locked tokens (effective circulating supply)
     * @return Effective circulating supply
     */
    function getEffectiveCirculatingSupply() external view returns (uint256) {
        uint256 total = totalSupply();
        if (total > totalLockedTokens) {
            return total - totalLockedTokens;
        }
        return 0;
    }
}
