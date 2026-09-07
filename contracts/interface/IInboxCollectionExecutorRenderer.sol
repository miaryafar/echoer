// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Inbox NFT renderer interface
/// @notice Describes the facts needed to build one Inbox receipt token URI.
/// @dev Renderer calls are read-only. They do not own or change the NFT.
interface IInboxCollectionExecutorRenderer is IERC165 {
    struct MessageData {
        /// @dev Echo counter assigned within the sender's history.
        uint32 messageId;
        /// @dev Unix timestamp stored by the Inbox.
        uint40 sentAt;
        /// @dev Must be the actual value validated by the calling Inbox.
        uint256 value;
        string message;
    }

    /// @notice Inputs used to build one Inbox NFT token URI.
    /// @dev Keep this struct synchronized with the Inbox collection call site.
    struct TokenURIInput {
        address echoerCore;
        address collection;
        address sender;
        address receiver;
        address nftOwner;
        uint256 tokenId;
        /// @dev Wall-owner display preference. When true, the renderer prefers
        /// ENS for both sides. When false, claimed Echoer names are preferred,
        /// but ENS is still tried for a 27-character unclaimed Echoer identity.
        bool preferENS;
        MessageData echo;
    }

    /// @notice Builds an Inbox NFT's metadata URI.
    function tokenURI(
        TokenURIInput calldata input
    ) external view returns (string memory);
}
