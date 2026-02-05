// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/token/ERC20/extensions/draft-ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/*
 * @title DSCGovernanceToken
 * @author CableGraph
 * @notice Governance token for the Decentralized StableCoin protocol
 * @dev Features:
 * - Voting power delegation (ERC20Votes) for on-chain governance
 * - Gasless approvals (ERC20Permit) for better UX
 * - Controlled minting by DSCEngine only
 * - Integrated with your existing error and event patterns
 */
contract DSCGovernanceToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    error DSCGovernanceToken__OnlyEngineCanMint();
    error DSCGovernanceToken__MintAmountZero();
    error DSCGovernanceToken__BurnAmountZero();
    error DSCGovernanceToken__TransferToZeroAddress();
    error DSCGovernanceToken__MaxSupplyExceeded();
    error DSCGovernanceToken__MintingDisabled();
    error DSCGovernanceToken__InvalidEngineAddress();

    address private s_dscEngine;
    bool private s_mintingEnabled = true;
    uint256 private s_maxSupply;
    uint256 private s_governanceTokenMintRate;

    event MintingToggled(bool enabled);
    event MaxSupplyUpdated(uint256 oldMax, uint256 newMax);
    event EngineAddressUpdated(address oldEngine, address newEngine);
    event GovernanceTokensMinted(address indexed to, uint256 amount, uint256 dscAmount);
    event GovernanceTokensBurned(address indexed from, uint256 amount);
    event MintRateUpdated(uint256 oldRate, uint256 newRate);
    event VotingPowerDelegated(address indexed delegator, address indexed delegatee);

    uint256 public constant DEFAULT_MINT_RATE = 0.1e18;
    uint256 public constant DEFAULT_MAX_SUPPLY = 10_000_000e18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;

    /**
     * @param engineAddress Address of the DSCEngine contract
     * @param initialRecipient Address to receive initial supply (usually deployer/timelock)
     */
    constructor(address engineAddress, address initialRecipient)
        ERC20("DSC Governance", "DSCG")
        ERC20Permit("DSC Governance")
    {
        if (engineAddress == address(0)) {
            revert DSCGovernanceToken__InvalidEngineAddress();
        }
        if (initialRecipient == address(0)) {
            revert DSCGovernanceToken__TransferToZeroAddress();
        }

        s_dscEngine = engineAddress;
        s_maxSupply = DEFAULT_MAX_SUPPLY;
        s_governanceTokenMintRate = DEFAULT_MINT_RATE;

        _mint(initialRecipient, INITIAL_SUPPLY);

        _transferOwnership(msg.sender);
    }

    /**
     * @notice Mint new governance tokens proportional to DSC minted
     * @dev Only callable by the DSCEngine contract when users mint DSC
     * @param to Address to receive the minted governance tokens
     * @param dscAmount Amount of DSC being minted (used to calculate governance tokens)
     */
    function mintForDSC(address to, uint256 dscAmount) external returns (uint256) {
        if (msg.sender != s_dscEngine) {
            revert DSCGovernanceToken__OnlyEngineCanMint();
        }

        if (dscAmount == 0) {
            revert DSCGovernanceToken__MintAmountZero();
        }
        if (!s_mintingEnabled) {
            revert DSCGovernanceToken__MintingDisabled();
        }

        uint256 governanceAmount = (dscAmount * s_governanceTokenMintRate) / 1e18;

        if (governanceAmount == 0) {
            governanceAmount = 1;
        }

        if (s_maxSupply > 0 && totalSupply() + governanceAmount > s_maxSupply) {
            revert DSCGovernanceToken__MaxSupplyExceeded();
        }

        _mint(to, governanceAmount);
        emit GovernanceTokensMinted(to, governanceAmount, dscAmount);

        return governanceAmount;
    }

    /**
     * @notice Burn governance tokens
     * @dev Only callable by the DSCEngine contract
     * @param from Address whose tokens to burn
     * @param amount Amount to burn (in wei)
     */
    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != s_dscEngine) {
            revert DSCGovernanceToken__OnlyEngineCanMint();
        }
        if (amount == 0) {
            revert DSCGovernanceToken__BurnAmountZero();
        }

        _burn(from, amount);
        emit GovernanceTokensBurned(from, amount);
    }

    /**
     * @notice Delegate voting power to another address
     * @param delegatee Address to delegate voting power to
     */
    function delegate(address delegatee) public virtual override {
        super.delegate(delegatee);
        emit VotingPowerDelegated(msg.sender, delegatee);
    }

    /**
     * @notice Delegate voting power from a specific address (using permit)
     * @param delegatee Address receiving voting power
     * @param v Signature v component
     * @param r Signature r component
     * @param s Signature s component
     */
    function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        public
        virtual
        override
    {
        super.delegateBySig(delegatee, nonce, expiry, v, r, s);
        emit VotingPowerDelegated(msg.sender, delegatee);
    }

    /**
     * @notice Toggle minting on/off
     * @dev Only owner (governance/timelock) can toggle minting
     * @param enabled Whether minting should be enabled
     */
    function toggleMinting(bool enabled) external onlyOwner {
        s_mintingEnabled = enabled;
        emit MintingToggled(enabled);
    }

    /**
     * @notice Update the maximum token supply
     * @dev Only owner (governance/timelock) can update max supply
     * @param newMaxSupply New maximum supply (0 for unlimited)
     */
    function updateMaxSupply(uint256 newMaxSupply) external onlyOwner {
        uint256 oldMax = s_maxSupply;
        s_maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(oldMax, newMaxSupply);
    }

    /**
     * @notice Update the DSCEngine address
     * @dev Only owner (governance/timelock) can update engine address
     * @param newEngineAddress New DSCEngine contract address
     */
    function updateEngineAddress(address newEngineAddress) external onlyOwner {
        if (newEngineAddress == address(0)) {
            revert DSCGovernanceToken__InvalidEngineAddress();
        }
        address oldEngine = s_dscEngine;
        s_dscEngine = newEngineAddress;
        emit EngineAddressUpdated(oldEngine, newEngineAddress);
    }

    /**
     * @notice Update the governance token mint rate
     * @dev Only owner (governance/timelock) can update mint rate
     * @param newMintRate New mint rate (governance tokens per DSC in wei)
     */
    function updateMintRate(uint256 newMintRate) external onlyOwner {
        uint256 oldRate = s_governanceTokenMintRate;
        s_governanceTokenMintRate = newMintRate;
        emit MintRateUpdated(oldRate, newMintRate);
    }

    /**
     * @notice Get the current DSCEngine address
     */
    function getDscEngine() external view returns (address) {
        return s_dscEngine;
    }

    /**
     * @notice Check if minting is currently enabled
     */
    function isMintingEnabled() external view returns (bool) {
        return s_mintingEnabled;
    }

    /**
     * @notice Get the maximum token supply
     */
    function getMaxSupply() external view returns (uint256) {
        return s_maxSupply;
    }

    /**
     * @notice Get the current governance token mint rate
     */
    function getMintRate() external view returns (uint256) {
        return s_governanceTokenMintRate;
    }

    /**
     * @notice Calculate governance tokens for a given DSC amount
     * @param dscAmount Amount of DSC being minted
     * @return governanceAmount Governance tokens to mint
     */
    function calculateGovernanceTokens(uint256 dscAmount) external view returns (uint256) {
        uint256 governanceAmount = (dscAmount * s_governanceTokenMintRate) / 1e18;
        return governanceAmount > 0 ? governanceAmount : 1;
    }

    /**
     * @notice Get current voting power (number of votes) for an account
     * @param account Address to check voting power for
     * @return Current voting power
     */
    function getVotes(address account) public view override returns (uint256) {
        return super.getVotes(account);
    }

    /**
     * @notice Get past voting power for an account at a specific block
     * @param account Address to check voting power for
     * @param blockNumber Block number to check at
     * @return Voting power at that block
     */
    function getPastVotes(address account, uint256 blockNumber) public view override returns (uint256) {
        return super.getPastVotes(account, blockNumber);
    }

    /**
     * @notice Get past total supply at a specific block
     * @param blockNumber Block number to check at
     * @return Total supply at that block
     */
    function getPastTotalSupply(uint256 blockNumber) public view override returns (uint256) {
        return super.getPastTotalSupply(blockNumber);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }
}
