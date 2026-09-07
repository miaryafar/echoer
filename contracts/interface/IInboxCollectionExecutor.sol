// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Incoming Echo app interface
/// @notice Lets a Wall send selected incoming Echoes to a connected app.
/// @dev Echoer calls these functions an executor. Its write callbacks are
/// protocol entry points and should accept calls only from the bound Wall.
/// `echoValue` is the full value received; `msg.value` depends on Wall policy.
interface IInboxCollectionExecutor is IERC165 {
    /// @notice Handles an incoming message routed by the bound Wall.
    /// @param echoValue Original ETH value received by the Wall for this Echo.
    function onEchoInFromWall(
        address owner,
        address from,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message
    ) external payable;

    /// @notice Handles an incoming message with application data.
    /// @param echoValue Original ETH value received by the Wall for this Echo.
    function onEchoInWithDataFromWall(
        address owner,
        address from,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message,
        bytes calldata data
    ) external payable;

    /// @notice Checks whether the app would accept an Echo without writing.
    /// @return allowed True when the app would accept it.
    /// @return reason Empty when allowed; otherwise a readable explanation.
    function canEchoInFromWall(
        address owner,
        address from,
        bytes32 fromInfo,
        uint256 value,
        bool forwardValueToExecutor,
        string calldata message,
        bytes calldata data
    ) external view returns (
        bool allowed,
        string memory reason
    );
}
