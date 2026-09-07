// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Echo NFT renderer interface
/// @notice Describes the facts needed to build one Echo token URI.
/// @dev Renderer calls are read-only. They do not own or change the NFT.
interface IEchoCollectionExecutorRenderer is IERC165 {
    /// @notice Immutable Echo facts used by the renderer.
    struct EchoData {
        uint32 echoId;
        /// @dev Unix timestamp of the Echo, supplied by the calling contract.
        uint40 echoedAt;
        string message;
    }

    /// @notice Immutable facts needed to render one Echo.
    /// @dev Current name and Wall data are read from `echoerCore` when rendered.
    struct TokenURIInput {
        address echoerCore;
        address collection;
        address echoer;
        uint256 tokenId;
        /// @dev RGB colors. If both are zero, the default colors are used.
        bytes3 backgroundColor;
        bytes3 foregroundColor;
        /// @dev Wall-owner display preference. When true, ENS is preferred.
        /// When false, ENS is tried only if Echoer returns its unclaimed
        /// 27-character address identity.
        bool preferENS;
        EchoData echo;
    }

    /// @notice Builds an Echo NFT's metadata URI.
    function tokenURI(
        TokenURIInput calldata input
    ) external view returns (string memory);
}
