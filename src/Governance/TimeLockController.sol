// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {TimelockController} from "@openzeppelin/governance/TimelockController.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";

/**
 * @title DSCTimelock
 * @author CableGraph
 * @notice Timelock controller for DSC protocol governance
 * @dev Adds DSC-specific functionality and safety features
 *
 * Purpose: Acts as a safety buffer for execution
 * - Provides a delay (e.g., 2 days) before approved changes take effect
 * - Prevents immediate execution of malicious proposals
 * - Gives users time to exit if they disagree with changes
 */
contract DSCTimelock is TimelockController {
    //////////////////
    //// ERRORS /////
    ////////////////
    error DSCTimelock__OperationTooShort(uint256 currentDelay, uint256 minDelay);
    error DSCTimelock__OperationTooLong(uint256 currentDelay, uint256 maxDelay);
    error DSCTimelock__InvalidCallData(address target, bytes4 selector);
    error DSCTimelock__CriticalOperationNoGracePeriod();
    error DSCTimelock__EmergencyOperationOnly();
    error DSCTimelock__ZeroAddressNotAllowed();

    ///////////////////
    //// EVENTS //////
    ////////////////
    event OperationScheduled(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        uint256 delay
    );
    event OperationExecuted(bytes32 indexed id, uint256 indexed index);
    event OperationCanceled(bytes32 indexed id);
    event MinDelayChanged(uint256 oldDuration, uint256 newDuration);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event EmergencyExecuted(bytes32 indexed id, address indexed executor);

    //////////////////////
    //// CONSTANTS //////
    ////////////////////
    uint256 public constant DEFAULT_MIN_DELAY = 2 days; // 2-day safety buffer
    uint256 public constant MAX_DELAY = 7 days; // Maximum delay allowed
    uint256 public constant EMERGENCY_EXECUTION_DELAY = 6 hours; // For critical issues

    // Critical operations that need extra scrutiny
    bytes4 private constant CRITICAL_SELECTORS = bytes4(keccak256("pause()"));
    bytes4 private constant EMERGENCY_SELECTORS = bytes4(keccak256("emergencyWithdraw(address)"));

    //////////////////////
    //// STATE VARS /////
    ////////////////////
    uint256 private s_minDelay;
    uint256 private s_maxDelay;
    mapping(address => bool) private s_guardians;
    mapping(bytes32 => bool) private s_emergencyOperations;

    // Custom roles for your protocol
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_EXECUTOR_ROLE = keccak256("EMERGENCY_EXECUTOR_ROLE");

    /**
     * @param initialAdmin Initial admin address (will be multisig/governance)
     * @param proposers Array of addresses that can propose operations
     * @param executors Array of addresses that can execute operations
     * @param guardians Array of guardian addresses for emergency oversight
     */
    constructor(
        address initialAdmin,
        address[] memory proposers,
        address[] memory executors,
        address[] memory guardians
    ) TimelockController(DEFAULT_MIN_DELAY, proposers, executors, initialAdmin) {
        s_minDelay = DEFAULT_MIN_DELAY;
        s_maxDelay = MAX_DELAY;

        // Setup guardians
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == address(0)) {
                revert DSCTimelock__ZeroAddressNotAllowed();
            }
            s_guardians[guardians[i]] = true;
            emit GuardianAdded(guardians[i]);
        }

        // Grant custom roles
        _grantRole(GUARDIAN_ROLE, initialAdmin);
        for (uint256 i = 0; i < guardians.length; i++) {
            _grantRole(GUARDIAN_ROLE, guardians[i]);
        }
    }

    //////////////////////////////
    //// EXTERNAL FUNCTIONS /////
    ////////////////////////////

    /**
     * @notice Schedule an operation for execution
     * @dev Overridden to add DSC-specific validations
     * @param target Target address (e.g., DSCEngine)
     * @param value ETH value to send
     * @param data Calldata for the operation
     * @param predecessor Predecessor operation (for dependency)
     * @param salt Unique salt for the operation
     * @param delay Custom delay (optional, uses minDelay if 0)
     */
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        // Validate delay
        uint256 operationDelay = delay > 0 ? delay : getMinDelay();

        if (operationDelay < s_minDelay) {
            revert DSCTimelock__OperationTooShort(operationDelay, s_minDelay);
        }
        if (operationDelay > s_maxDelay) {
            revert DSCTimelock__OperationTooLong(operationDelay, s_maxDelay);
        }

        // Validate target and calldata for critical operations
        _validateOperation(target, data, operationDelay);

        // Call parent schedule
        super.schedule(target, value, data, predecessor, salt, operationDelay);

        // Emit custom event
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        emit OperationScheduled(id, 0, target, value, data, predecessor, operationDelay);
    }

    /**
     * @notice Schedule a batch of operations
     * @dev For multiple operations in one proposal
     * @param targets Array of target addresses
     * @param values Array of ETH values
     * @param payloads Array of calldata
     * @param predecessor Predecessor operation
     * @param salt Unique salt
     * @param delay Custom delay (optional)
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        // Validate delay
        uint256 operationDelay = delay > 0 ? delay : getMinDelay();

        if (operationDelay < s_minDelay) {
            revert DSCTimelock__OperationTooShort(operationDelay, s_minDelay);
        }
        if (operationDelay > s_maxDelay) {
            revert DSCTimelock__OperationTooLong(operationDelay, s_maxDelay);
        }

        // Validate each operation
        for (uint256 i = 0; i < targets.length; i++) {
            _validateOperation(targets[i], payloads[i], operationDelay);
        }

        // Call parent scheduleBatch
        super.scheduleBatch(targets, values, payloads, predecessor, salt, operationDelay);

        // Emit events for each operation
        for (uint256 i = 0; i < targets.length; i++) {
            bytes32 id = hashOperation(targets[i], values[i], payloads[i], predecessor, salt);
            emit OperationScheduled(id, i, targets[i], values[i], payloads[i], predecessor, operationDelay);
        }
    }

    /**
     * @notice Execute an operation
     * @dev Overridden to add DSC-specific logging
     * @param target Target address
     * @param value ETH value to send
     * @param payload Calldata for the operation
     * @param predecessor Predecessor operation
     * @param salt Unique salt
     */
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
        onlyRoleOrOpenRole(EXECUTOR_ROLE)
    {
        // Call parent execute
        super.execute(target, value, payload, predecessor, salt);

        // Emit custom event
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        emit OperationExecuted(id, 0);
    }

    /**
     * @notice Execute a batch of operations
     * @param targets Array of target addresses
     * @param values Array of ETH values
     * @param payloads Array of calldata
     * @param predecessor Predecessor operation
     * @param salt Unique salt
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override onlyRoleOrOpenRole(EXECUTOR_ROLE) {
        // Call parent executeBatch
        super.executeBatch(targets, values, payloads, predecessor, salt);

        // Emit events for each operation
        for (uint256 i = 0; i < targets.length; i++) {
            bytes32 id = hashOperation(targets[i], values[i], payloads[i], predecessor, salt);
            emit OperationExecuted(id, i);
        }
    }

    /**
     * @notice Emergency execution (by guardians only)
     * @dev For critical situations where normal delay is too long
     * @param target Target address
     * @param value ETH value to send
     * @param payload Calldata for the operation
     * @param predecessor Predecessor operation
     * @param salt Unique salt
     */
    function emergencyExecute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        // Validate it's an emergency operation
        bytes4 selector = _getSelector(payload);
        if (selector != EMERGENCY_SELECTORS) {
            revert DSCTimelock__EmergencyOperationOnly();
        }

        // Mark as emergency operation
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        s_emergencyOperations[id] = true;

        // Execute with emergency delay
        uint256 oldMinDelay = getMinDelay();
        _updateDelay(EMERGENCY_EXECUTION_DELAY);

        super.execute(target, value, payload, predecessor, salt);

        // Restore original delay
        _updateDelay(oldMinDelay);

        emit EmergencyExecuted(id, msg.sender);
    }

    /**
     * @notice Update minimum delay
     * @dev Only governance can update delay (through timelock itself)
     * @param newDelay New minimum delay
     */
    function updateMinDelay(uint256 newDelay) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (newDelay > s_maxDelay) {
            revert DSCTimelock__OperationTooLong(newDelay, s_maxDelay);
        }
        if (newDelay < 1 hours) {
            revert DSCTimelock__OperationTooShort(newDelay, 1 hours);
        }

        uint256 oldDelay = s_minDelay;
        s_minDelay = newDelay;

        // Update the timelock's internal delay
        _updateDelay(newDelay);

        emit MinDelayChanged(oldDelay, newDelay);
    }

    /**
     * @notice Add a guardian address
     * @dev Only admin can add guardians
     * @param guardian Address to add as guardian
     */
    function addGuardian(address guardian) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (guardian == address(0)) {
            revert DSCTimelock__ZeroAddressNotAllowed();
        }
        if (s_guardians[guardian]) {
            revert("Already guardian");
        }

        s_guardians[guardian] = true;
        _grantRole(GUARDIAN_ROLE, guardian);

        emit GuardianAdded(guardian);
    }

    /**
     * @notice Remove a guardian address
     * @dev Only admin can remove guardians
     * @param guardian Address to remove from guardians
     */
    function removeGuardian(address guardian) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (!s_guardians[guardian]) {
            revert("Not a guardian");
        }

        s_guardians[guardian] = false;
        _revokeRole(GUARDIAN_ROLE, guardian);

        emit GuardianRemoved(guardian);
    }

    //////////////////////////////////
    //// INTERNAL FUNCTIONS /////////
    ////////////////////////////////

    /**
     * @dev Validate operation based on target and calldata
     * @param target Target contract address
     * @param data Calldata for the operation
     * @param delay Proposed delay
     */
    function _validateOperation(address target, bytes calldata data, uint256 delay) internal view {
        // Extract function selector
        if (data.length < 4) return; // Not a function call

        bytes4 selector = _getSelector(data);

        // Critical operations (pause) need longer delay
        if (selector == CRITICAL_SELECTORS) {
            if (delay < 3 days) {
                revert DSCTimelock__CriticalOperationNoGracePeriod();
            }
        }

        // Prevent certain operations through timelock
        if (target == address(this)) {
            // Prevent changing timelock delay to very short period
            if (selector == bytes4(keccak256("updateDelay(uint256)"))) {
                if (delay < 3 days) {
                    revert DSCTimelock__CriticalOperationNoGracePeriod();
                }
            }
        }
    }

    /**
     * @dev Extract function selector from calldata
     * @param data Calldata
     * @return selector Function selector
     */
    function _getSelector(bytes calldata data) internal pure returns (bytes4 selector) {
        assembly {
            selector := calldataload(data.offset)
        }
    }

    //////////////////////////////////
    //// VIEW/PURE FUNCTIONS ////////
    ////////////////////////////////

    /**
     * @notice Check if an address is a guardian
     * @param account Address to check
     * @return True if the address is a guardian
     */
    function isGuardian(address account) external view returns (bool) {
        return s_guardians[account];
    }

    /**
     * @notice Get minimum delay
     * @return Current minimum delay
     */
    function getMinDelay() public view override returns (uint256) {
        return s_minDelay;
    }

    /**
     * @notice Get maximum delay
     * @return Current maximum delay
     */
    function getMaxDelay() external view returns (uint256) {
        return s_maxDelay;
    }

    /**
     * @notice Check if operation is marked as emergency
     * @param id Operation ID
     * @return True if operation is emergency
     */
    function isEmergencyOperation(bytes32 id) external view returns (bool) {
        return s_emergencyOperations[id];
    }

    /**
     * @notice Get operation details
     * @param id Operation ID
     * @return timestamp When the operation becomes ready
     * @return executed If the operation was executed
     */
    function getOperation(bytes32 id) external view returns (uint256 timestamp, bool executed) {
        return (getTimestamp(id), isOperationDone(id));
    }

    /**
     * @notice Get all pending operations
     * @return Array of operation IDs that are pending
     */
    function getPendingOperations() external view returns (bytes32[] memory) {
        // This would need to track all operations
        // Simplified version - in production you'd track this
        return new bytes32[](0);
    }

    /**
     * @notice Calculate operation hash
     * @param target Target address
     * @param value ETH value
     * @param data Calldata
     * @param predecessor Predecessor
     * @param salt Unique salt
     * @return Operation hash
     */
    function computeOperationId(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return hashOperation(target, value, data, predecessor, salt);
    }
}
