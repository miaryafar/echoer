// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Outgoing Echo app interface
/// @notice Lets a Wall send selected self-Echoes to a connected app.
/// @dev Echoer calls these functions an executor. Its write callbacks are
/// protocol entry points and should accept calls only from the bound Wall.
interface IEchoCollectionExecutor is IERC165 {
    /// @notice Handles a message routed by the bound Wall.
    function onEchoFromWall(
        address owner,
        uint32 eID,
        string calldata message
    ) external;

    /// @notice Handles a routed message with application data.
    function onEchoWithDataFromWall(
        address owner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    ) external;

    /// @notice Checks whether the app would accept a message without writing.
    /// @return allowed True when the app would accept it.
    /// @return reason Empty when allowed; otherwise a readable explanation.
    function canEchoFromWall(
        address owner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    ) external view returns (
        bool allowed,
        string memory reason
    );
}
