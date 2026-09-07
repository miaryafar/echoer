// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Simple ownership interface
/// @notice Lets Echoer read the owner of another contract.
/// @dev Used only when ownership may extend permission to a contract owner.
interface IOwnable {
    /// @notice Returns the contract owner.
    function owner() external view returns (address);
}
