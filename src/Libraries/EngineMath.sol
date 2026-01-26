// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

library EngineMath {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error MathMasters__MulWadFailed();
    error MathMasters__DivWadFailed();
    error MathMasters__AddFailed();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_UINT256 = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                         FIXED POINT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev (x * y) / WAD rounded down, with overflow protection
    function mulWad(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            // Check for overflow: y != 0 && x > type(uint256).max / y
            if mul(y, gt(x, div(not(0), y))) {
                mstore(0x40, 0xbac65e5b) // `MathMasters__MulWadFailed()`.
                revert(0x1c, 0x04)
            }
            z := div(mul(x, y), WAD)
        }
    }

    /// @dev (x * y) / WAD rounded up, with overflow protection
    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            // Check for overflow
            if mul(y, gt(x, div(not(0), y))) {
                mstore(0x40, 0xbac65e5b) // `MathMasters__MulWadFailed()`.
                revert(0x1c, 0x04)
            }
            // Add 1 if there's a remainder
            if iszero(iszero(mod(mul(x, y), WAD))) {
                z := 1
            }
            z := add(z, div(mul(x, y), WAD))
        }
    }

    /// @dev (x * WAD) / y rounded down, with overflow protection
    function divWad(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            // Check for division by zero
            if iszero(y) {
                mstore(0x40, 0x65244e4e) // `MathMasters__DivWadFailed()`.
                revert(0x1c, 0x04)
            }
            // Check for overflow: x > type(uint256).max / WAD
            if gt(x, div(not(0), WAD)) {
                mstore(0x40, 0x65244e4e) // `MathMasters__DivWadFailed()`.
                revert(0x1c, 0x04)
            }
            z := div(mul(x, WAD), y)
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DSC-ENGINE SPECIFIC OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Health factor calculation: (collateral * numerator) / totalDSCMinted
    /// @dev Returns MAX_UINT256 if totalDSCMinted is 0 (no debt)
    function calculateHealthFactor(
        uint256 collateralValueInUsd,
        uint256 healthFactorNumerator,
        uint256 totalDSCMinted
    ) internal pure returns (uint256) {
        if (totalDSCMinted == 0) return MAX_UINT256;

        // (collateralValueInUsd * healthFactorNumerator) / totalDSCMinted
        return
            mulWad(collateralValueInUsd, healthFactorNumerator) /
            totalDSCMinted;
    }

    /// @dev USD value calculation with token decimal normalization
    /// @param amount Token amount in its native decimals
    /// @param price Price in USD with 18 decimals
    /// @param tokenDecimals Token's native decimals (e.g., 18 for ETH, 6 for USDC)
    function calculateUsdValue(
        uint256 amount,
        uint256 price,
        uint8 tokenDecimals
    ) internal pure returns (uint256) {
        if (amount == 0) return 0;

        if (tokenDecimals == 18) {
            // Already in 18 decimals, use mulWad directly
            return mulWad(amount, price);
        }

        // Normalize to 18 decimals then multiply
        uint256 normalizedAmount = amount * (10 ** (18 - tokenDecimals));
        return mulWad(normalizedAmount, price);
    }

    /// @dev Token amount from USD with token decimal denormalization
    /// @param usdAmount Amount in USD (18 decimals)
    /// @param price Price in USD with 18 decimals
    /// @param tokenDecimals Token's native decimals
    function calculateTokenAmount(
        uint256 usdAmount,
        uint256 price,
        uint8 tokenDecimals
    ) internal pure returns (uint256) {
        if (price == 0) return MAX_UINT256; // Avoid division by zero

        // Get amount in 18 decimals: (usdAmount * WAD) / price
        uint256 amount18 = divWad(usdAmount, price);

        if (tokenDecimals == 18) {
            return amount18;
        }

        // Convert from 18 decimals to token's native decimals
        return amount18 / (10 ** (18 - tokenDecimals));
    }

    /// @dev Safe multiplication with overflow check for liquidation calculations
    function safeMul(uint256 a, uint256 b) internal pure returns (uint256) {
        assembly {
            // Check for overflow
            if gt(a, div(not(0), b)) {
                mstore(0x40, 0xbac65e5b) // `MathMasters__MulWadFailed()`.
                revert(0x1c, 0x04)
            }
            let product := mul(a, b)
            mstore(0x00, product)
            return(0x00, 0x20)
        }
    }

    /// @dev Safe division with zero check
    function safeDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        assembly {
            if iszero(b) {
                mstore(0x40, 0x65244e4e) // `MathMasters__DivWadFailed()`.
                revert(0x1c, 0x04)
            }
            let result := div(a, b)
            mstore(0x00, result)
            return(0x00, 0x20)
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns min(a, b)
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Returns max(a, b)
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @dev Checks if a - b would underflow
    function wouldUnderflow(uint256 a, uint256 b) internal pure returns (bool) {
        return b > a;
    }

    /// @dev Safe subtraction with underflow check
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "Math: subtraction underflow");
        return a - b;
    }
    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        if (c < a) revert MathMasters__AddFailed();
        return c;
    }
}
