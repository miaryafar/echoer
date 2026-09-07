// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Short-name packing helper
/// @notice Packs a 1-to-18-byte name and restores it later.
/// @dev Internal developer helper, not a user-facing contract. Length is
/// measured in encoded bytes, not visible characters. It does not validate the
/// allowed Echoer name alphabet.
abstract contract nameHelp {
    /// @dev Thrown when packed name data claims more than 18 bytes.
    error NameTooLong();

    /// @dev Packs a name into left-aligned `bytes18` plus its length. This form
    /// fits beside the other EchoerInfo fields in one storage slot.
    function _packName(string memory name) internal pure returns (bytes18 data, uint8 len) {
        uint256 l = bytes(name).length;
        if (l > 18) revert ("TooLong Name: max 18 bytes");
        if (l == 0) revert("Empty name");
        len = uint8(l);

        assembly {
            // Load the first 32 bytes; the first character is on the left.
            let w := mload(add(name, 0x20))

            // Clear bytes after the name.
            let sh := shl(3, sub(32, l))     // (32-l)*8
            let mask := shl(sh, not(0))
            w := and(w, mask)

            data := w
        }
    }

    /// @dev Restores a packed name. Zero length means no claimed name.
    function _unpackName(bytes18 data, uint8 len) internal pure returns (string memory name) {
        if (len == 0) return "";
        if (len > 18) revert NameTooLong();

        assembly {
            // Allocate the output string.
            name := mload(0x40)
            mstore(name, len)

            // Clear any stray bytes after the declared length.
            let w := data
            let sh := shl(3, sub(32, len))     // (32-len)*8
            let mask := shl(sh, not(0))        // 0xFF..FF00..00
            w := and(w, mask)

            mstore(add(name, 0x20), w)

            // Advance to the next aligned memory word.
            let rounded := and(add(len, 31), not(31))
            mstore(0x40, add(add(name, 0x20), rounded))
        }
    }
}
