// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 *                      H A S H   T O   D A T A
 *
 *        Give the registry public bytes or text.
 *        It returns keccak256(data) and lets anyone read the data later.
 *        Repeating the same data keeps the same hash and stored value.
 *
 *        There is no owner, private mode, edit or delete function.
 */

/// @title Hash-to-data registry
/// @notice Permissionless public storage keyed by `keccak256(data)`.
/// @dev An empty value is indistinguishable from a missing value.
contract HashToDataRegistry {
    mapping(bytes32 => bytes) private _dataOf;

    /// @notice Returns the bytes stored under `hash`.
    function dataOf(bytes32 hash)
        external
        view
        returns (bytes memory)
    {
        return _dataOf[hash];
    }

    /// @notice Returns the stored bytes as a Solidity string.
    function stringOf(bytes32 hash)
        external
        view
        returns (string memory)
    {
        return string(_dataOf[hash]);
    }

    /// @notice Returns the number of bytes stored under `hash`.
    function dataLength(bytes32 hash)
        external
        view
        returns (uint256)
    {
        return _dataOf[hash].length;
    }

    /// @notice Stores bytes under their keccak256 hash.
    function store(bytes calldata data)
        external
        returns (bytes32)
    {
        return _store(data);
    }

    /// @notice Stores a string under the hash of its bytes.
    function storeString(string calldata data)
        external
        returns (bytes32)
    {
        return _store(bytes(data));
    }

    /// @notice Returns the keccak256 hash of a string's bytes.
    function hashOf(string calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(bytes(data));
    }

    /// @dev Avoids rewriting existing non-empty data.
    function _store(bytes calldata data)
        private
        returns (bytes32 hash)
    {
        hash = keccak256(data);

        if (_dataOf[hash].length == 0) {
            _dataOf[hash] = data;
        }
    }
}
