// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Historic Echo interface
/// @notice Lets the new Echoer publish its launch message in the older Echo.
/// @dev Deployment-only dependency. It is not used for normal Echoer messages.
interface ITornadoCashEchoer {
    /// @notice A public byte message was posted.
    event Echo(address indexed who, bytes data);

    /// @notice Posts a public byte message.
    function echo(bytes calldata data) external;
}
