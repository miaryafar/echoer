// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IEchoerDataStore
/// @notice Public API for storing and reading shared Echoer data.
/// @dev Developer interface. Ordinary Echoer users do not need to call it.
/// A reference returned by `store` can be read later from this same contract;
/// references from another store must not be mixed in.
interface IEchoerDataStore {
    /// @notice Largest payload held directly inside a data reference.
    function INLINE_MAX_LENGTH() external view returns (uint256);

    /// @notice Smallest payload held in one packed contract storage slot.
    function PACKED_STORAGE_MIN_LENGTH() external view returns (uint256);

    /// @notice Largest payload held in one packed contract storage slot.
    function PACKED_STORAGE_MAX_LENGTH() external view returns (uint256);

    /// @notice Smallest payload stored in deterministic bytecode.
    function BYTECODE_MIN_LENGTH() external view returns (uint256);

    /// @notice Largest payload supported by one EIP-170-compatible data contract.
    function MAX_DATA_LENGTH() external view returns (uint256);

    /// @notice Type byte used by deterministic-bytecode references.
    function BYTECODE_REFERENCE_TYPE() external view returns (uint8);

    /// @notice Reads a canonical reference, returning empty bytes when invalid.
    function dataOf(bytes21 dataRef) external view returns (bytes memory data);

    /// @notice Reads a canonical reference as a Solidity string.
    function stringOf(
        bytes21 dataRef
    ) external view returns (string memory data);

    /// @notice Reads an inline or packed reference as a single left-aligned word.
    /// @dev Returns `valid == false` for bytecode references and for malformed
    ///      references. Bytes past `length` in `word` are always zero.
    function wordOf(
        bytes21 dataRef
    ) external view returns (bool valid, bytes32 word, uint256 length);

    /// @notice Stores bytes and returns their canonical `bytes21` reference.
    function store(bytes calldata data) external returns (bytes21 dataRef);

    /// @notice Stores a string and returns its canonical `bytes21` reference.
    function storeString(
        string calldata data
    ) external returns (bytes21 dataRef);

    /// @notice Computes the canonical reference without writing storage.
    function referenceOf(
        bytes calldata data
    ) external view returns (bytes21 dataRef);

    /// @notice Computes the canonical reference for a string without storing it.
    function referenceOfString(
        string calldata data
    ) external view returns (bytes21 dataRef);

    /// @notice Returns the payload length, or zero for an invalid reference.
    function dataLength(
        bytes21 dataRef
    ) external view returns (uint256 length);

    /// @notice Returns whether a reference is canonical and backed by data.
    function exists(bytes21 dataRef) external view returns (bool);
}
