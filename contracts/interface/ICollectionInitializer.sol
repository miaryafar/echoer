// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Echoer collection initializer
/// @notice Binds a new collection clone to the Wall that created it.
/// @dev Protocol use only. Implementations must reject a second call.
interface ICollectionInitializer {
    /// @notice Initializes the clone for its calling Wall.
    function initialize() external;
}
