// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Simple owned account interface
/// @notice Lets Echoer initialize an account and read its owner.
/// @dev This is an integration interface, not a normal user entry point.
interface IAccount {
    /// @notice Initializes the account for its owner.
    function initialize(address) external;

    /// @notice Returns the account owner.
    function owner() external view returns (address);
}
