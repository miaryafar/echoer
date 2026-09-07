// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.27;


/// @notice Stores one account's name and Echo activity in one 256-bit slot.
/// @dev Storage layout (bit positions, low to high):
///        [0–7]       nameLen         (uint8)
///        [8–23]      createdAtWeek   (uint16)
///        [24–55]     lastEchoOutMinute (uint32)
///        [56–87]     echoCount       (uint32)
///        [88–111]    echoOutCount    (uint24)
///        [112–255]   nameData        (bytes18 = 144 bits, right-padded)
///
/// All fields fit in one slot, saving gas on storage. Solidity packs structs
/// from low to high memory addresses, matching this layout.
struct EchoerInfo {
    uint8 nameLen;
    uint16 createdAtWeek;
    uint32 lastEchoOutMinute;
    uint32 echoCount;
    uint24 echoOutCount;
    bytes18 nameData;
}

/// @notice Reads EchoerInfo exactly as it is stored.
/// @dev Pass this raw slot to Walls without repacking it.
library EchoerInfoLib {
    function load(
        EchoerInfo storage info
    ) internal view returns (bytes32 packedInfo) {
        assembly ("memory-safe") {
            packedInfo := sload(info.slot)
        }
    }

    /// @dev nameLen starts at bit 0. nameData starts at bit 112.
    function nameParts(
        bytes32 packedInfo
    ) internal pure returns (bytes18 nameData, uint8 nameLen) {
        assembly ("memory-safe") {
            nameData := and(packedInfo, shl(112, not(0)))
            nameLen := and(packedInfo, 0xff)
        }
    }

    /// @dev lastEchoOutMinute starts at bit 24.
    function lastEchoOutMinute(
        bytes32 packedInfo
    ) internal pure returns (uint32 minute) {
        assembly ("memory-safe") {
            minute := and(shr(24, packedInfo), 0xffffffff)
        }
    }

    /// @dev echoCount starts at bit 56; echoOutCount starts at bit 88.
    function echoCounts(
        bytes32 packedInfo
    ) internal pure returns (uint32 echoCount, uint24 echoOutCount) {
        assembly ("memory-safe") {
            echoCount := and(shr(56, packedInfo), 0xffffffff)
            echoOutCount := and(shr(88, packedInfo), 0xffffff)
        }
    }
}
