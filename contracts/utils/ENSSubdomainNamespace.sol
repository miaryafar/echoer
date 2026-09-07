// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
 *                     . E T H   N A M E   H E L P E R
 *
 *        addressOf("alice") looks up alice.eth.
 *        nameOf(account) returns a verified primary .eth name.
 *
 *        Inputs are relative to .eth and may include nested labels.
 *        Invalid names and resolver failures return zero or an empty string.
 *        This helper reads ENS; it does not register or change ENS names.
 */

/// @title Echoer namespace interface
/// @notice Resolves names inside one external naming system.
interface IEchoerNamespace {
    /// @notice Resolves a name relative to this namespace.
    /// @param subname The name excluding this namespace's registered name.
    function addressOf(
        string calldata subname
    ) external view returns (address owner);

    /// @notice Returns the account's name relative to this namespace.
    /// @return subname The name excluding this namespace's registered name.
    function nameOf(
        address account
    ) external view returns (string memory subname);
}

/// @title ENS Universal Resolver interface
/// @dev Minimal read-only surface used by this helper.
interface IUniversalResolver {
    /// @notice Resolves encoded DNS name data through ENS.
    function resolve(
        bytes calldata name,
        bytes calldata data
    ) external view returns (
        bytes memory result,
        address resolver
    );

    /// @notice Finds the primary ENS name for an address.
    function reverse(
        bytes calldata lookupAddress,
        uint256 coinType
    ) external view returns (
        string memory primary,
        address resolver,
        address reverseResolver
    );
}

/// @title ENS address resolver interface
/// @dev Minimal interface for an Ethereum address record.
interface IAddressResolver {
    /// @notice Returns the Ethereum address stored for an ENS node.
    function addr(bytes32 node) external view returns (address);
}

/// @title Echoer .eth namespace helper
/// @notice Resolves direct and nested names below `.eth` without reverting.
/// @dev `addressOf("alice")` resolves `alice.eth`; `nameOf` removes `.eth`
/// from a verified primary name. Invalid or unavailable records return zero or
/// an empty string. Inputs accept lowercase letters, digits, and internal
/// hyphens. The fixed Universal Resolver remains governed by ENS, and off-chain
/// resolver records may not complete during a contract call.
contract EthNamespace is IEchoerNamespace {
    /// @notice Official ENS Universal Resolver proxy.
    address private constant UNIVERSAL_RESOLVER =
        0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe;

    /// @dev SLIP-44 coin type for Ethereum.
    uint256 private constant ETH_COIN_TYPE = 60;

    /// @dev Precomputed namehash of `eth`.
    bytes32 private constant ETH_NODE =
        0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    bytes1 private constant DOT = 0x2e;
    bytes1 private constant HYPHEN = 0x2d;

    /// @inheritdoc IEchoerNamespace
    /// @dev The input is relative to `.eth`. Invalid names, missing records,
    /// malformed results, and resolver failures return the zero address.
    function addressOf(
        string calldata name
    ) external view override returns (address owner) {
        // Read the string bytes without copying them first.
        bytes calldata relativeName = bytes(name);

        (
            bool valid,
            bytes memory dnsName,
            bytes32 node
        ) = _encodeAndHashEthName(relativeName);

        if (!valid) {
            return address(0);
        }

        bytes memory resolverCall = abi.encodeCall(
            IAddressResolver.addr,
            (node)
        );

        try IUniversalResolver(UNIVERSAL_RESOLVER).resolve(
            dnsName,
            resolverCall
        )
            returns (
                bytes memory result,
                address /* resolver */
            )
        {
            // A valid encoded address result is exactly one word.
            if (result.length != 32) {
                return address(0);
            }

            uint256 resultWord;

            assembly ("memory-safe") {
                resultWord := mload(add(result, 0x20))
            }

            owner = address(uint160(resultWord));
        } catch {
            owner = address(0);
        }
    }

    /// @inheritdoc IEchoerNamespace
    /// @dev Returns only a verified primary `.eth` name and removes the final
    /// suffix. Nested names stay intact. Failures return an empty string.
    function nameOf(
        address account
    )
        external
        view
        override
        returns (string memory name)
    {
        if (account == address(0)) {
            return "";
        }

        try IUniversalResolver(UNIVERSAL_RESOLVER).reverse(
            abi.encodePacked(account),
            ETH_COIN_TYPE
        )
            returns (
                string memory primary,
                address /* resolver */,
                address /* reverseResolver */
            )
        {
            return _removeEthSuffix(primary);
        } catch {
            return "";
        }
    }

    /// @dev Validates a relative name, DNS-encodes it with `.eth`, and computes
    /// its ENS namehash without a temporary label array.
    function _encodeAndHashEthName(
        bytes calldata relativeName
    )
        private
        pure
        returns (
            bool valid,
            bytes memory dnsName,
            bytes32 node
        )
    {
        uint256 inputLength = relativeName.length;

        // DNS encoding adds six bytes and may not exceed 255 bytes.
        if (inputLength == 0 || inputLength > 249) {
            return (false, bytes(""), bytes32(0));
        }

        dnsName = new bytes(inputLength + 6);

        // Reserve the first label-length byte; later dots become length bytes.
        uint256 outputOffset = 1;
        uint256 lengthOffset;
        uint256 labelLength;

        for (uint256 i; i < inputLength;) {
            bytes1 character = relativeName[i];

            if (character == DOT) {
                if (
                    labelLength == 0 ||
                    labelLength > 63 ||
                    relativeName[i - 1] == HYPHEN
                ) {
                    return (false, bytes(""), bytes32(0));
                }

                dnsName[lengthOffset] =
                    bytes1(uint8(labelLength));

                // Reserve the next label-length byte.
                lengthOffset = outputOffset;

                unchecked {
                    ++outputOffset;
                }

                labelLength = 0;
            } else {
                if (
                    !_isValidCharacter(character) ||
                    (labelLength == 0 && character == HYPHEN)
                ) {
                    return (false, bytes(""), bytes32(0));
                }

                dnsName[outputOffset] = character;

                unchecked {
                    ++outputOffset;
                    ++labelLength;
                }

                if (labelLength > 63) {
                    return (false, bytes(""), bytes32(0));
                }
            }

            unchecked {
                ++i;
            }
        }

        if (
            labelLength == 0 ||
            relativeName[inputLength - 1] == HYPHEN
        ) {
            return (false, bytes(""), bytes32(0));
        }

        dnsName[lengthOffset] = bytes1(uint8(labelLength));

        // Append the DNS-encoded `.eth` suffix and root terminator.
        assembly ("memory-safe") {
            let suffixPointer :=
                add(add(dnsName, 0x20), outputOffset)

            mstore8(suffixPointer, 0x03)
            mstore8(add(suffixPointer, 1), 0x65)
            mstore8(add(suffixPointer, 2), 0x74)
            mstore8(add(suffixPointer, 3), 0x68)
            mstore8(add(suffixPointer, 4), 0x00)
        }

        node = ETH_NODE;

        // Build namehash from the rightmost relative label to the leftmost.
        uint256 labelEnd = inputLength;

        while (true) {
            uint256 labelStart = labelEnd;

            while (
                labelStart != 0 &&
                relativeName[labelStart - 1] != DOT
            ) {
                unchecked {
                    --labelStart;
                }
            }

            // DNS label content begins one byte after its dotted-input offset.
            bytes32 labelHash = _hashSlice(
                dnsName,
                labelStart + 1,
                labelEnd - labelStart
            );

            node = _extendNode(node, labelHash);

            if (labelStart == 0) {
                break;
            }

            // Skip the dot immediately before this label.
            unchecked {
                labelEnd = labelStart - 1;
            }
        }

        valid = true;
    }

    /// @dev Validates a primary name and removes its final `.eth` suffix.
    function _removeEthSuffix(
        string memory fullName
    ) private pure returns (string memory) {
        bytes memory full = bytes(fullName);
        uint256 fullLength = full.length;

        // The shortest supported name is `a.eth`.
        if (fullLength < 5) {
            return "";
        }

        uint256 relativeLength = fullLength - 4;

        // Require the exact normalized lowercase suffix `.eth`.
        if (
            full[relativeLength] != 0x2e ||
            full[relativeLength + 1] != 0x65 ||
            full[relativeLength + 2] != 0x74 ||
            full[relativeLength + 3] != 0x68
        ) {
            return "";
        }

        if (relativeLength > 249) {
            return "";
        }

        bytes memory relativeName =
            new bytes(relativeLength);

        uint256 labelLength;

        for (uint256 i; i < relativeLength;) {
            bytes1 character = full[i];

            if (character == DOT) {
                if (
                    labelLength == 0 ||
                    labelLength > 63 ||
                    full[i - 1] == HYPHEN
                ) {
                    return "";
                }

                labelLength = 0;
            } else {
                if (
                    !_isValidCharacter(character) ||
                    (labelLength == 0 && character == HYPHEN)
                ) {
                    return "";
                }

                unchecked {
                    ++labelLength;
                }

                if (labelLength > 63) {
                    return "";
                }
            }

            relativeName[i] = character;

            unchecked {
                ++i;
            }
        }

        if (
            labelLength == 0 ||
            relativeName[relativeLength - 1] == HYPHEN
        ) {
            return "";
        }

        return string(relativeName);
    }

    /// @dev Accepts lowercase ASCII letters, digits, and hyphens.
    function _isValidCharacter(
        bytes1 character
    ) private pure returns (bool) {
        bool lowercase =
            character >= 0x61 &&
            character <= 0x7a;

        bool digit =
            character >= 0x30 &&
            character <= 0x39;

        return lowercase || digit || character == HYPHEN;
    }

    /// @dev Hashes a memory slice without copying it.
    function _hashSlice(
        bytes memory data,
        uint256 start,
        uint256 length
    ) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := keccak256(
                add(add(data, 0x20), start),
                length
            )
        }
    }

    /// @dev Adds one label hash to an ENS namehash node.
    function _extendNode(
        bytes32 node,
        bytes32 labelHash
    ) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, node)
            mstore(0x20, labelHash)
            result := keccak256(0x00, 0x40)
        }
    }
}
