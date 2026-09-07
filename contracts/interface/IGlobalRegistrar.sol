// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Legacy global registrar interface
/// @notice Used by Echoer for temporary duplicate-name checks and `#` messages.
/// @dev This is a fixed external dependency, not the main Echoer name system.
/// Each `bytes32` argument is passed directly as the registrar's name key.
interface IGlobalRegistrar {
    /// @notice A registry name record changed.
    event Changed(bytes32 indexed name);

    /// @notice A registry name's primary address changed.
    event PrimaryChanged(bytes32 indexed name, address indexed addr);

    /// @notice Returns the owner/controller of a registry name.
    function owner(bytes32 nameKey) external view returns (address);

    /// @notice Returns the resolved address of a registry name.
    function addr(bytes32 nameKey) external view returns (address);

    /// @notice Returns the primary name linked to an address.
    function name(address owner_) external view returns (bytes32);

    /// @notice Reserves an unused name for the caller.
    /// @dev If Echo calls this, Echo becomes the registry owner/controller.
    function reserve(bytes32 nameKey) external payable;

    /// @notice Sets the resolved address for a name.
    /// @param primary If true, also sets reverse primary name for the address.
    function setAddress(
        bytes32 nameKey,
        address destination,
        bool primary
    ) external payable;

    /// @notice Transfers registry ownership of a name.
    function transfer(bytes32 nameKey, address newOwner) external payable;

    /// @notice Deletes/disowns a registry name.
    function disown(bytes32 nameKey) external payable;

    /// @notice Returns the sub-registrar address.
    function register(bytes32 nameKey) external view returns (address);

    /// @notice Returns the content value.
    function content(bytes32 nameKey) external view returns (bytes32);

    /// @notice Sets the content value.
    function setContent(bytes32 nameKey, bytes32 content_) external payable;

    /// @notice Sets the sub-registrar address.
    function setSubRegistrar(bytes32 nameKey, address registrar) external payable;
}
