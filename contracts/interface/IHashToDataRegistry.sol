// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Hash-to-data registry interface
/// @notice Stores public data under its own hash so anyone can read it later.
/// @dev The hash is the key. Stored data is permanent and has no private mode.
interface IHashToDataRegistry {
    /// @notice Returns the stored data associated with `hash`.
    /// @param hash The keccak256 hash of the stored data.
    /// @return data The stored bytes.
    function dataOf(bytes32 hash) external view returns (bytes memory data);

    /// @notice Returns stored data as a Solidity string.
    /// @dev Returns an empty string if no data exists.
    function stringOf(bytes32 hash) external view returns (string memory data);

    /// @notice Stores raw bytes under their own keccak256 hash.
    /// @param data Arbitrary bytes to store.
    /// @return hash keccak256(data).
    function store(bytes calldata data) external returns (bytes32 hash);

    /// @notice Stores a Solidity string under its keccak256 hash.
    /// @param data The string to store.
    /// @return hash keccak256(bytes(data)).
    function storeString(string calldata data) external returns (bytes32 hash);

    /// @notice Returns stored data length without loading the full bytes.
    /// @param hash The data hash.
    /// @return length Stored byte length.
    function dataLength(bytes32 hash) external view returns (uint256 length);

    /// @notice Calculates keccak256 hash of a string.
    /// @param data The string to hash.
    /// @return hash keccak256(bytes(data)).
    function hashOf(string calldata data) external pure returns (bytes32 hash);
}
