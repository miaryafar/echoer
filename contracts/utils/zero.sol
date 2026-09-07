// SPDX-License-Identifier: MIT

pragma solidity >=0.8.4;

/// @title Legacy string helpers
/// @notice Small byte and ASCII helpers kept for name integrations.
/// @dev Internal developer library, not a user-facing contract. Most checks
/// operate on encoded bytes. `strlen` estimates character count from leading
/// bytes but does not prove that the input is valid UTF-8.
library ZeroXnameStringUtils {
    /// @dev Counts characters from UTF-8 leading-byte widths. It does not
    /// validate the input as UTF-8.
    function strlen(string memory s) internal pure returns (uint256) {
        uint256 len;
        uint256 i = 0;
        uint256 bytelength = bytes(s).length;
        for (len = 0; i < bytelength; len++) {
            bytes1 b = bytes(s)[i];
            if (b < 0x80) {
                i += 1;
            } else if (b < 0xE0) {
                i += 2;
            } else if (b < 0xF0) {
                i += 3;
            } else if (b < 0xF8) {
                i += 4;
            } else if (b < 0xFC) {
                i += 5;
            } else {
                i += 6;
            }
        }
        return len;
    }

    /// @notice Returns whether the first byte is a dot.
    function isStartWithDot(
        string memory str
    ) internal pure returns (bool result) {
        assembly {
            let length := mload(str)
            if gt(length, 0) {
                str := add(str, 0x20)
                let firstChar := shr(248, mload(str))
                if eq(firstChar, 0x2E) {
                    result := true
                }
            }
        }
    }

    /// @notice Returns whether the last byte is a dot.
    function isEndWithDot(
        string memory str
    ) internal pure returns (bool result) {
        assembly {
            let length := mload(str)
            if gt(length, 0) {
                str := add(str, 0x20)
                let lastChar := shr(248, mload(add(str, sub(length, 1))))
                if eq(lastChar, 0x2E) {
                    result := true
                }
            }
        }
    }

    /// @notice Finds blocked punctuation, uppercase letters, or non-ASCII bytes.
    function containsForbiddenChars(
        string memory str
    ) internal pure returns (bool result) {
        assembly {
            let length := mload(str)
            str := add(str, 0x20)

            for {
                let i := 0
            } lt(i, length) {
                i := add(i, 1)
            } {
                let partialStr := add(str, i)
                let char := shr(248, mload(partialStr))
                switch char
                case 0x20 {

                } // space
                case 0x21 {

                } // !
                case 0x22 {

                } // "
                case 0x23 {

                } // #
                case 0x25 {

                } // %
                case 0x27 {

                } // '
                case 0x28 {

                } // (
                case 0x29 {

                } // )
                case 0x2C {

                } // ,
                case 0x3A {

                } // :
                case 0x3B {

                } // ;
                case 0x3F {

                } // ?
                case 0x40 {

                } // @
                case 0x5B {

                } // [
                case 0x5D {

                } // ]
                case 0x5C {

                } // \
                case 0x60 {

                } // `
                case 0x2F {

                } // /
                case 0x3D {

                } // =
                case 0x7B {

                } // {
                case 0x7D {

                } // }
                default {
                    if or(gt(char, 127), and(gt(char, 64), lt(char, 91))) {
                        result := true
                        break
                    }
                    continue
                }
                result := true
                break
            }
        }
    }

    /// @notice Changes ASCII letters to upper or lower case.
    /// @dev Adapted from Solady's LibString.
    function toCase(
        string memory subject,
        bool toUpper
    ) internal pure returns (string memory result) {
        assembly ("memory-safe") {
            let length := mload(subject)
            if length {
                result := add(mload(0x40), 0x20)
                subject := add(subject, 1)
                let flags := shl(add(70, shl(5, toUpper)), 0x3ffffff)
                let w := not(0)
                for {
                    let o := length
                } 1 {

                } {
                    o := add(o, w)
                    let b := and(0xff, mload(add(subject, o)))
                    mstore8(add(result, o), xor(b, and(shr(b, flags), 0x20)))
                    if iszero(o) {
                        break
                    }
                }
                result := mload(0x40)
                mstore(result, length) // Store the length.
                let last := add(add(result, 0x20), length)
                mstore(last, 0) // Zeroize the slot after the string.
                mstore(0x40, add(last, 0x20)) // Allocate the memory.
            }
        }
    }

    /// @notice Converts ASCII uppercase letters to lowercase.
    function tolower(
        string memory subject
    ) internal pure returns (string memory result) {
        return toCase(subject, false);
    }
}
