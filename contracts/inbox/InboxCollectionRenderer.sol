// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IInboxCollectionExecutorRenderer} from "./../interface/IInboxCollectionExecutorRenderer.sol";
import {IEchoer} from "./../interface/IEchoer.sol";

/*
 *                  I N B O X   R E N D E R E R
 *
 *        Turns an Inbox receipt into on-chain JSON and SVG artwork.
 *        It shows who sent the Echo, who received it, its time and value.
 *
 *        Long text is shortened only in the artwork.
 *        Blank text receives a label.
 *        Invalid UTF-8 is shown safely as Base64.
 *        JSON and SVG control characters are escaped.
 *
 *        This contract holds no NFTs, funds or editable settings.
 */

/// @title EchoerInboxRenderer
/// @notice Fully on-chain metadata and artwork for an Inbox receipt NFT.
/// @dev A leading `#` marks uniqueness but is not shown in the artwork.
contract EchoerInboxRenderer is ERC165, IInboxCollectionExecutorRenderer {
    using Strings for uint256;

    /// @notice Largest supported displayed name, measured in characters.
    uint256 public constant MAX_NAME_CHARACTERS = 27;

    /// @notice Largest artwork message, measured in UTF-8 characters.
    uint256 public constant MAX_MESSAGE_CHARACTERS = 200;

    uint256 private constant MAX_LINE_UNITS = 34;
    uint256 private constant MAX_LINES = 12;
    /// @dev Keeps message spacing compact on square artwork.
    uint256 private constant MESSAGE_UNIT_PERCENT = 45;
    uint256 private constant MARKER_CHARACTERS = 3;
    string private constant TRUNCATION_MARKER = "...";
    string private constant BLANK_MESSAGE = "[blank message]";
    string private constant BINARY_MESSAGE_PREFIX = "base64:";

    /// @dev Chain-specific reverse-name source used by the Echoer deployment.
    /// Calls are failure-tolerant: tokenURI falls back to the Echoer identity.
    address private constant DEFAULT_ENS_NAME_RESOLVER =
        0xab7E1E15b97185e3d1a6ED1653D25c1736DB5701;

    struct RenderData {
        string echoerCoreAddress;
        string messageId;
        string nftOwnerAddress;
        string senderName;
        string receiverName;
        string senderAddress;
        string senderWallAddress;
        string receiverAddress;
        string receiverWallAddress;
        string message;
        string echoDate;
        uint256 messageCharacters;
        uint256 value;
        uint40 sentAt;
        bool truncated;
        bool uniqueMessage;
        bool receiverIsOwner;
        bool senderNameClaimed;
        bool receiverNameClaimed;
        bool senderUsesENS;
        bool receiverUsesENS;
    }

    string private constant SVG_HEAD_BEFORE_BACKGROUND =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000"><title>Echoer Inbox message</title><rect width="1000" height="1000" fill="';
    string private constant SVG_BETWEEN_BACKGROUND_AND_INK =
        '"/><g color="';
    string private constant SVG_HEAD_AFTER_INK =
        '"><rect x="26" y="26" width="948" height="948" fill="none" stroke="currentColor" stroke-width="2"/><g transform="matrix(.056 0 0 .056 25.8 22.77)" fill="none" stroke="currentColor" stroke-width="34" stroke-linecap="round" stroke-linejoin="round"><path d="M682.155 629.142H1818.32V1752.6H682.155Z"/><path d="M1410.44 850.966C876.028 1204.88 1023.91 1275.11 1435.21 1530.77"/><path d="M1090.03 1530.77C1175.98 1473.86 1244.28 1424.28 1296.67 1380.08C1570.07 1149.47 1410.42 1065.51 1065.27 850.966"/></g><text x="144" y="73" fill="currentColor" font-family="monospace" font-size="18" font-weight="700" letter-spacing="7" text-anchor="start">ECHOER</text><text x="144" y="97" fill="currentColor" opacity=".68" font-family="monospace" font-size="13" letter-spacing=".35" text-anchor="start" direction="ltr">';
    string private constant SVG_AFTER_ECHOER_CORE_ADDRESS =
        '</text><text x="144" y="120" fill="currentColor" opacity=".68" font-family="monospace" font-size="10" letter-spacing="1.75" text-anchor="start">ECHOER INBOX / PERMANENT MESSAGING</text><line x1="64" y1="146" x2="936" y2="146" stroke="currentColor"/>';
    string private constant SVG_BEFORE_SENDER =
        '<text x="80" y="174" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing="3" text-anchor="start">FROM</text><text x="80" y="205" fill="currentColor" font-family="monospace" font-size="21" letter-spacing=".35" text-anchor="start" unicode-bidi="plaintext">';
    string private constant SVG_AFTER_SENDER_NAME =
        '</text><text x="80" y="228" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing=".15" text-anchor="start" direction="ltr">';
    string private constant SVG_BEFORE_RECEIVER =
        '</text><text x="920" y="174" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing="3" text-anchor="end">TO</text><text x="920" y="205" fill="currentColor" font-family="monospace" font-size="21" letter-spacing=".35" text-anchor="end" unicode-bidi="plaintext">';
    string private constant SVG_BEFORE_OWNER_RECEIVER_NAME =
        '</text><text x="920" y="228" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing=".15" text-anchor="end" unicode-bidi="plaintext">';
    string private constant SVG_BEFORE_RECEIVER_WALLET =
        '</text><text x="920" y="228" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing=".15" text-anchor="end" direction="ltr">';
    string private constant SVG_AFTER_RECEIVER_ROW =
        '</text><line x1="64" y1="248" x2="936" y2="248" stroke="currentColor"/>';
    string private constant SVG_UNIQUE_MESSAGE_LABEL =
        '<text x="500" y="278" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" font-weight="700" letter-spacing="3" text-anchor="middle">UNIQUE MESSAGE</text>';
    string private constant SVG_BEFORE_ECHO_VALUE =
        '<line x1="64" y1="870" x2="936" y2="870" stroke="currentColor"/><text x="80" y="910" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing="1.5" text-anchor="start">ECHO VALUE / ';
    string private constant SVG_BEFORE_ECHO_DATE =
        '</text><text x="920" y="910" fill="currentColor" opacity=".68" font-family="monospace" font-size="12" letter-spacing="1.5" text-anchor="end">DATE / ';
    string private constant SVG_END = '</text></g></svg>';

    string private constant METADATA_DESCRIPTION_CLAIMED =
        'This NFT records a message sent through Echoer and serves as a receipt for that message.';
    string private constant METADATA_DESCRIPTION_UNCLAIMED =
        'This Inbox NFT was created when a message was sent to this Ethereum address through Echoer. It serves as a receipt for that message. This address currently uses its Echoer address identity and has not claimed a permanent name yet. A permanent Echoer name can be claimed later.';
    string private constant METADATA_DESCRIPTION_COMMON =
        ' The Echoer Wall linked to this address provides its received-message history. Echoer is an on-chain protocol that gives Ethereum addresses permanent names, messaging, and their own Walls.';

    error InvalidPackedNameLength(uint8 length);

    /// @notice Returns the reverse-name resolver used for optional ENS names.
    function ensNameResolver() public pure returns (address) {
        return DEFAULT_ENS_NAME_RESOLVER;
    }

    /// @notice Reports the ERC-165 interfaces supported by this renderer.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IInboxCollectionExecutorRenderer).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Returns a complete ERC-721 tokenURI.
    /// @dev The calling Inbox must supply the validated message value.
    function tokenURI(TokenURIInput calldata input)
        external
        view override
        returns (string memory)
    {
        RenderData memory data;
        data.echoerCoreAddress = Strings.toHexString(input.echoerCore);
        data.messageId = Strings.toString(uint256(input.echo.messageId));
        address nftOwner = input.nftOwner;
        if (nftOwner == address(0)) {
            revert("NFT owner cannot be zero");
        }
        data.nftOwnerAddress = Strings.toHexString(nftOwner);
        data.senderAddress = Strings.toHexString(input.sender);
        data.senderWallAddress = Strings.toHexString(IEchoer(input.echoerCore).wallOf(input.sender));
        data.receiverAddress = Strings.toHexString(input.receiver);
        data.receiverWallAddress = Strings.toHexString(IEchoer(input.echoerCore).wallOf(input.receiver));
        data.value = input.echo.value;
        data.sentAt = input.echo.sentAt;
        data.echoDate = _formatDate(input.echo.sentAt);

        (data.senderName, data.senderNameClaimed) =
            _echoerName(IEchoer(input.echoerCore).packedNameOf(input.sender));
        (data.receiverName, data.receiverNameClaimed) =
            _echoerName(IEchoer(input.echoerCore).packedNameOf(input.receiver));

        if (input.preferENS || !data.senderNameClaimed) {
            string memory senderENSName = _tryENSName(input.sender);
            if (bytes(senderENSName).length != 0) {
                data.senderName = senderENSName;
                data.senderUsesENS = true;
            }
        }

        if (input.preferENS || !data.receiverNameClaimed) {
            string memory receiverENSName = _tryENSName(input.receiver);
            if (bytes(receiverENSName).length != 0) {
                data.receiverName = receiverENSName;
                data.receiverUsesENS = true;
            }
        }

        data.receiverIsOwner = nftOwner == input.receiver;

        string memory messageContent;
        (messageContent, data.uniqueMessage) =
            _messageContent(input.echo.message);
        (data.message, data.messageCharacters, data.truncated) =
            _prepareMessage(messageContent);

        return _tokenURI(data);
    }

    function _tokenURI(RenderData memory data)
        private
        pure
        returns (string memory)
    {
        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(_svg(data)))
        );

        bytes memory identityStart = abi.encodePacked(
            '{"name":"',
            _escapeJSON(_tokenName(data.senderName)),
            '","description":"',
            data.receiverNameClaimed
                ? METADATA_DESCRIPTION_CLAIMED
                : METADATA_DESCRIPTION_UNCLAIMED
        );
        bytes memory identityEnd = abi.encodePacked(
            METADATA_DESCRIPTION_COMMON,
            '","image":"',
            image,
            '"'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes.concat(identityStart, identityEnd, _attributes(data))
            )
        );
    }

    function _attributes(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            _coreAttributes(data),
            _senderAttributes(data),
            _receiverAttributes(data),
            _messageAttributes(data)
        );
    }

    function _coreAttributes(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory core = abi.encodePacked(
            ',"attributes":[{"trait_type":"Echoer Core","value":"',
            data.echoerCoreAddress,
            '"},{"trait_type":"Echoer Message ID","value":"',
            data.messageId
        );
        return abi.encodePacked(
            core,
            '"},{"trait_type":"NFT Owner","value":"',
            data.nftOwnerAddress,
            '"}'
        );
    }

    function _senderAttributes(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory identity = abi.encodePacked(
            ',{"trait_type":"Sender Name","value":"',
            _escapeJSON(data.senderName),
            '"},{"trait_type":"Sender Identity Source","value":"',
            data.senderUsesENS ? "ENS" : "Echoer"
        );
        bytes memory addresses = abi.encodePacked(
            '"},{"trait_type":"Sender Address","value":"',
            data.senderAddress
        );
        return abi.encodePacked(
            identity,
            addresses,
            '"},{"trait_type":"Sender Wall Address","value":"',
            data.senderWallAddress,
            '"}'
        );
    }

    function _receiverAttributes(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory identity = abi.encodePacked(
            ',{"trait_type":"Receiver Name","value":"',
            _escapeJSON(data.receiverName),
            '"},{"trait_type":"Receiver Name Status","value":"',
            data.receiverNameClaimed
                ? "Claimed"
                : "Unclaimed"
        );
        bytes memory sourceAndAddress = abi.encodePacked(
            '"},{"trait_type":"Receiver Identity Source","value":"',
            data.receiverUsesENS ? "ENS" : "Echoer",
            '"},{"trait_type":"Receiver Address","value":"',
            data.receiverAddress
        );
        return abi.encodePacked(
            identity,
            sourceAndAddress,
            '"},{"trait_type":"Receiver Wall Address","value":"',
            data.receiverWallAddress,
            '"}'
        );
    }

    function _messageAttributes(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory valueAttributes = abi.encodePacked(
            '},{"trait_type":"Value Band","value":"',
            _valueBand(data.value),
            '"}'
        );
        if (data.value != 0) {
            valueAttributes = abi.encodePacked(
                valueAttributes,
                ',{"trait_type":"Echo Value Wei","value":"',
                data.value.toString(),
                '"}'
            );
        }

        bytes memory displayed = abi.encodePacked(
            ',{"display_type":"number","trait_type":"Displayed Characters","value":',
            data.messageCharacters.toString()
        );
        bytes memory timing = abi.encodePacked(
            ',{"trait_type":"Echo Date","value":"',
            data.echoDate,
            '"},{"display_type":"date","trait_type":"Sent At","value":',
            uint256(data.sentAt).toString(),
            '}'
        );
        bytes memory messageType = abi.encodePacked(
            ',{"trait_type":"Message Type","value":"',
            data.uniqueMessage ? "Unique" : "Standard",
            '"}'
        );
        bytes memory truncated = abi.encodePacked(
            ',{"trait_type":"Truncated","value":"',
            data.truncated ? "Yes" : "No",
            '"}]}'
        );
        return bytes.concat(
            displayed,
            valueAttributes,
            timing,
            messageType,
            truncated
        );
    }

    function _svg(RenderData memory data)
        private
        pure
        returns (string memory)
    {
        bytes memory output = _svgHeader(data);
        output = bytes.concat(output, _svgIdentityRow(data));
        if (data.uniqueMessage) {
            output = bytes.concat(output, bytes(SVG_UNIQUE_MESSAGE_LABEL));
        }
        output = bytes.concat(output, bytes(_renderMessage(data.message)));
        output = bytes.concat(output, _svgFooter(data));
        return string(output);
    }

    function _svgHeader(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory colors = abi.encodePacked(
            SVG_HEAD_BEFORE_BACKGROUND,
            _backgroundColor(data.value),
            SVG_BETWEEN_BACKGROUND_AND_INK,
            _inkColor(data.value)
        );
        bytes memory title = abi.encodePacked(
            SVG_HEAD_AFTER_INK,
            _shortAddress(data.echoerCoreAddress),
            SVG_AFTER_ECHOER_CORE_ADDRESS
        );
        return bytes.concat(colors, title);
    }

    function _svgIdentityRow(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory sender = abi.encodePacked(
            SVG_BEFORE_SENDER,
            _escapeXML(data.senderName),
            SVG_AFTER_SENDER_NAME
        );
        bytes memory addressLine = abi.encodePacked(
            "ADDRESS / ",
            _shortAddress(data.senderAddress)
        );
        return bytes.concat(sender, addressLine, _svgRecipient(data));
    }

    function _svgRecipient(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        if (data.receiverIsOwner) {
            bytes memory ownerLabel = abi.encodePacked(
                SVG_BEFORE_RECEIVER,
                "THIS ADDRESS",
                SVG_BEFORE_OWNER_RECEIVER_NAME
            );
            bytes memory ownerIdentity = abi.encodePacked(
                _escapeXML(data.receiverName),
                " / ",
                _shortAddress(data.receiverAddress)
            );
            return abi.encodePacked(
                ownerLabel,
                ownerIdentity,
                SVG_AFTER_RECEIVER_ROW
            );
        }

        bytes memory receiver = abi.encodePacked(
            SVG_BEFORE_RECEIVER,
            _escapeXML(data.receiverName),
            SVG_BEFORE_RECEIVER_WALLET
        );
        bytes memory wallet = abi.encodePacked(
            "ADDRESS / ",
            _shortAddress(data.receiverAddress)
        );
        return abi.encodePacked(
            receiver,
            wallet,
            SVG_AFTER_RECEIVER_ROW
        );
    }

    function _svgFooter(RenderData memory data)
        private
        pure
        returns (bytes memory)
    {
        bytes memory valueLine = abi.encodePacked(
            SVG_BEFORE_ECHO_VALUE,
            _formatEther(data.value),
            SVG_BEFORE_ECHO_DATE
        );
        return abi.encodePacked(
            valueLine,
            data.echoDate,
            SVG_END
        );
    }

    function _backgroundColor(uint256 value)
        private
        pure
        returns (string memory)
    {
        if (value == 0) return "#F3F0E8";
        if (value < 1e15) return "#E8EFF2";
        if (value < 1e16) return "#E2EBDD";
        if (value < 1e17) return "#EFE4BD";
        if (value < 1 ether) return "#EBCB9A";
        return "#111111";
    }

    function _inkColor(uint256 value)
        private
        pure
        returns (string memory)
    {
        return value >= 1 ether ? "#DDBB61" : "#111111";
    }

    function _valueBand(uint256 value)
        private
        pure
        returns (string memory)
    {
        if (value == 0) return "0 ETH";
        if (value < 1e15) return "<0.001 ETH";
        if (value < 1e16) return "0.001-0.01 ETH";
        if (value < 1e17) return "0.01-0.1 ETH";
        if (value < 1 ether) return "0.1-1 ETH";
        return "1 ETH+";
    }

    function _formatEther(uint256 value)
        private
        pure
        returns (string memory)
    {
        uint256 whole = value / 1 ether;
        uint256 fraction = value % 1 ether;
        if (fraction == 0) {
            return string.concat(whole.toString(), " ETH");
        }

        bytes memory fractionDigits = new bytes(18);
        for (uint256 i = 18; i > 0; --i) {
            fractionDigits[i - 1] =
                bytes1(uint8(48 + (fraction % 10)));
            fraction /= 10;
        }

        uint256 end = 18;
        while (fractionDigits[end - 1] == "0") --end;

        bytes memory trimmed = new bytes(end);
        for (uint256 i; i < end; ++i) {
            trimmed[i] = fractionDigits[i];
        }

        return string.concat(
            whole.toString(),
            ".",
            string(trimmed),
            " ETH"
        );
    }

    /// @dev Formats Unix seconds as a Gregorian UTC calendar date. Time of
    ///      day is intentionally omitted from the permanent NFT artwork.
    function _formatDate(uint40 sentAt)
        private
        pure
        returns (string memory)
    {
        uint256 z = (uint256(sentAt) / 1 days) + 719468;
        uint256 era = z / 146097;
        uint256 dayOfEra = z - (era * 146097);
        uint256 yearOfEra = (
            dayOfEra - (dayOfEra / 1460) + (dayOfEra / 36524)
                - (dayOfEra / 146096)
        ) / 365;
        uint256 year = yearOfEra + (era * 400);
        uint256 dayOfYear = dayOfEra
            - (365 * yearOfEra + (yearOfEra / 4) - (yearOfEra / 100));
        uint256 monthPrime = ((5 * dayOfYear) + 2) / 153;
        uint256 day = dayOfYear - (((153 * monthPrime) + 2) / 5) + 1;
        uint256 month = monthPrime < 10
            ? monthPrime + 3
            : monthPrime - 9;
        if (month <= 2) ++year;

        return string.concat(
            year.toString(),
            "-",
            _twoDigits(month),
            "-",
            _twoDigits(day)
        );
    }

    function _twoDigits(uint256 value)
        private
        pure
        returns (string memory)
    {
        return value < 10
            ? string.concat("0", value.toString())
            : value.toString();
    }

    function _tokenName(string memory senderName)
        private
        pure
        returns (string memory)
    {
        return string.concat("Echoer Inbox from ", senderName);
    }

    /// @dev Name bytes are left-aligned in `packedName`; byte 31 stores the
    ///      byte length. 1-18 is a claimed name and 27 is an unclaimed
    ///      identity supplied directly by the caller.
    function _echoerName(bytes32 packedName)
        private
        pure
        returns (string memory name, bool claimed)
    {
        uint8 nameLen = uint8(uint256(packedName));
        if (nameLen == 0 || (nameLen > 18 && nameLen != 27)) {
            revert InvalidPackedNameLength(nameLen);
        }
        return (_unpackName(packedName, nameLen), nameLen <= 18);
    }

    function _unpackName(
        bytes32 packedName,
        uint8 len
    ) private pure returns (string memory unpackedName) {
        assembly ("memory-safe") {
            unpackedName := mload(0x40)
            mstore(unpackedName, and(len, 0xff))
            mstore(add(unpackedName, 0x20), packedName)
            mstore(0x40, add(unpackedName, 0x40))
        }
    }

    function _shortAddress(string memory addressValue)
        private
        pure
        returns (string memory)
    {
        bytes memory input = bytes(addressValue);
        if (input.length <= 13) return addressValue;

        bytes memory output = new bytes(13);
        for (uint256 i; i < 6; ++i) output[i] = input[i];
        output[6] = ".";
        output[7] = ".";
        output[8] = ".";
        for (uint256 i; i < 4; ++i) {
            output[9 + i] = input[input.length - 4 + i];
        }
        return string(output);
    }

    function _messageContent(string memory message)
        private
        pure
        returns (string memory content, bool uniqueMessage)
    {
        bytes memory data = bytes(message);
        uint256 start;
        if (data.length != 0 && data[0] == 0x23) {
            start = _skipWhitespace(data, 1);
            uniqueMessage = true;
        }

        content = _slice(data, start, data.length);
        bytes memory contentData = bytes(content);
        if (
            contentData.length == 0 ||
            !_containsVisibleCharacter(contentData)
        ) {
            return (BLANK_MESSAGE, uniqueMessage);
        }
        if (!_isValidUTF8(contentData)) {
            return (
                string.concat(
                    BINARY_MESSAGE_PREFIX,
                    Base64.encode(contentData)
                ),
                uniqueMessage
            );
        }
        return (content, uniqueMessage);
    }

    function _prepareMessage(string memory message)
        private
        pure
        returns (
            string memory displayed,
            uint256 displayedCharacters,
            bool truncated
        )
    {
        bytes memory data = bytes(message);
        uint256 characters = _characterCount(data);
        bytes memory prepared = data;

        if (characters > MAX_MESSAGE_CHARACTERS) {
            uint256 characterEnd = _prefixEnd(
                data,
                MAX_MESSAGE_CHARACTERS - MARKER_CHARACTERS
            );
            prepared = _appendMarker(
                data,
                _trimTrailingWhitespace(data, characterEnd)
            );
            truncated = true;
        }

        (uint256 lineEnd, bool exceedsLineLimit) =
            _lineLimitEnd(prepared);
        if (exceedsLineLimit) {
            lineEnd = _trimTrailingWhitespace(prepared, lineEnd);
            lineEnd = _retreatCharacters(
                prepared,
                lineEnd,
                MARKER_CHARACTERS
            );
            prepared = _appendMarker(
                prepared,
                _trimTrailingWhitespace(prepared, lineEnd)
            );
            truncated = true;
        }

        return (string(prepared), _characterCount(prepared), truncated);
    }

    function _appendMarker(bytes memory data, uint256 end)
        private
        pure
        returns (bytes memory shortened)
    {
        bytes memory marker = bytes(TRUNCATION_MARKER);
        shortened = new bytes(end + marker.length);
        for (uint256 i; i < end; ++i) shortened[i] = data[i];
        for (uint256 i; i < marker.length; ++i) {
            shortened[end + i] = marker[i];
        }
    }

    function _lineLimitEnd(bytes memory data)
        private
        pure
        returns (uint256 end, bool truncated)
    {
        uint256 cursor = _skipInlineWhitespace(data, 0);
        for (uint256 line; line < MAX_LINES; ++line) {
            end = _wordLineEnd(data, cursor);
            uint256 next = _nextLineStart(data, end);
            if (next >= data.length) return (data.length, false);
            if (line + 1 == MAX_LINES) return (end, true);
            cursor = next;
        }
    }

    function _retreatCharacters(
        bytes memory data,
        uint256 end,
        uint256 count
    ) private pure returns (uint256) {
        while (end != 0 && count != 0) {
            unchecked {
                --end;
                --count;
            }
            while (
                end != 0 &&
                uint8(data[end]) & 0xC0 == 0x80
            ) {
                unchecked {
                    --end;
                }
            }
        }
        return end;
    }

    function _prefixEnd(
        bytes memory data,
        uint256 maximumCharacters
    ) private pure returns (uint256 cursor) {
        uint256 characters;

        while (cursor < data.length && characters < maximumCharacters) {
            cursor += _utf8SequenceLength(uint8(data[cursor]));
            ++characters;
        }
    }

    function _trimTrailingWhitespace(bytes memory data, uint256 end)
        private
        pure
        returns (uint256)
    {
        while (end > 0 && _isWhitespace(data[end - 1])) --end;
        return end;
    }

    function _renderMessage(string memory message)
        private
        pure
        returns (string memory)
    {
        bytes memory data = bytes(message);
        uint256 lines = _lineCount(data);
        (uint256 fontSize, uint256 lineHeight) =
            _messageTypography(lines);
        uint256 startY =
            570 - (((lines - 1) * lineHeight) / 2);

        bytes memory result = abi.encodePacked(
            '<g fill="currentColor" font-family="serif" font-size="',
            fontSize.toString(),
            '" text-anchor="middle">'
        );

        uint256 byteStart = _skipInlineWhitespace(data, 0);
        for (uint256 line; line < lines; ++line) {
            uint256 byteEnd = _wordLineEnd(data, byteStart);

            result = bytes.concat(
                result,
                _renderMessageLine(
                    data,
                    byteStart,
                    byteEnd,
                    startY + (line * lineHeight),
                    fontSize
                )
            );
            byteStart = _nextLineStart(data, byteEnd);
        }

        return string(abi.encodePacked(result, "</g>"));
    }

    function _renderMessageLine(
        bytes memory data,
        uint256 byteStart,
        uint256 byteEnd,
        uint256 y,
        uint256 fontSize
    ) private pure returns (bytes memory) {
        bytes memory position = abi.encodePacked(
            '<text x="500" y="',
            y.toString(),
            '" unicode-bidi="plaintext" lengthAdjust="spacingAndGlyphs" textLength="'
        );
        position = abi.encodePacked(
            position,
            _messageTextLength(data, byteStart, byteEnd, fontSize).toString()
        );
        return abi.encodePacked(
            position,
            '">',
            _escapeXML(_slice(data, byteStart, byteEnd)),
            "</text>"
        );
    }

    function _messageTypography(uint256 lines)
        private
        pure
        returns (uint256 fontSize, uint256 lineHeight)
    {
        if (lines <= 4) return (50, 56);
        if (lines <= 7) return (46, 52);
        return (42, 46);
    }

    function _messageTextLength(
        bytes memory data,
        uint256 start,
        uint256 end,
        uint256 fontSize
    ) private pure returns (uint256 textLength) {
        uint256 visualUnits;
        for (uint256 cursor = start; cursor < end;) {
            visualUnits += _visualUnitsAt(data, cursor);
            cursor += _utf8SequenceLength(uint8(data[cursor]));
        }

        textLength =
            (visualUnits * fontSize * MESSAGE_UNIT_PERCENT) / 100;
        if (textLength == 0) textLength = 1;
    }

    function _tryENSName(address account)
        private
        view
        returns (string memory)
    {
        try IENSNameResolver(ensNameResolver()).nameOf(account) returns (
            string memory name
        ) {
            if (bytes(name).length == 0) return "";
            string memory displayName = string.concat(name, "@eth");
            if (_isUsableDisplayName(displayName)) return displayName;
        } catch {
            // A metadata read must not fail only because the optional resolver
            // is absent or temporarily unavailable.
        }
        return "";
    }

    function _isUsableDisplayName(string memory name)
        private
        pure
        returns (bool)
    {
        bytes memory data = bytes(name);
        return data.length != 0 && _containsVisibleCharacter(data)
            && _isValidUTF8(data)
            && _characterCount(data) <= MAX_NAME_CHARACTERS;
    }

    function _characterCount(bytes memory data)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < data.length; ++count) {
            i += _utf8SequenceLength(uint8(data[i]));
        }
    }

    /// @dev Returns a conservative display width: narrow code points use one
    ///      unit, CJK/full-width/emoji code points use two, and combining or
    ///      formatting code points use zero.
    function _visualUnitsAt(bytes memory data, uint256 cursor)
        private
        pure
        returns (uint256)
    {
        uint256 codePoint = _codePointAt(data, cursor);
        if (_isZeroWidthCodePoint(codePoint)) return 0;
        return _isWideCodePoint(codePoint) ? 2 : 1;
    }

    function _codePointAt(bytes memory data, uint256 cursor)
        private
        pure
        returns (uint256)
    {
        uint256 first = uint8(data[cursor]);
        uint256 sequenceLength = _utf8SequenceLength(uint8(first));
        if (sequenceLength == 1) return first;

        uint256 second = uint8(data[cursor + 1]);
        if (sequenceLength == 2) {
            return ((first & 0x1F) << 6) | (second & 0x3F);
        }

        uint256 third = uint8(data[cursor + 2]);
        if (sequenceLength == 3) {
            return ((first & 0x0F) << 12)
                | ((second & 0x3F) << 6)
                | (third & 0x3F);
        }

        uint256 fourth = uint8(data[cursor + 3]);
        return ((first & 0x07) << 18)
            | ((second & 0x3F) << 12)
            | ((third & 0x3F) << 6)
            | (fourth & 0x3F);
    }

    function _isZeroWidthCodePoint(uint256 codePoint)
        private
        pure
        returns (bool)
    {
        return (codePoint >= 0x0300 && codePoint <= 0x036F)
            || (codePoint >= 0x1AB0 && codePoint <= 0x1AFF)
            || (codePoint >= 0x1DC0 && codePoint <= 0x1DFF)
            || (codePoint >= 0x20D0 && codePoint <= 0x20FF)
            || (codePoint >= 0xFE00 && codePoint <= 0xFE0F)
            || (codePoint >= 0xFE20 && codePoint <= 0xFE2F)
            || (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF)
            || (codePoint >= 0xE0020 && codePoint <= 0xE007F)
            || (codePoint >= 0xE0100 && codePoint <= 0xE01EF)
            || (codePoint >= 0x200B && codePoint <= 0x200D);
    }

    function _isWideCodePoint(uint256 codePoint)
        private
        pure
        returns (bool)
    {
        return (codePoint >= 0x1100 && codePoint <= 0x115F)
            || (codePoint >= 0x2329 && codePoint <= 0x232A)
            || (codePoint >= 0x2600 && codePoint <= 0x27BF)
            || (codePoint >= 0x2E80 && codePoint <= 0xA4CF)
            || (codePoint >= 0xAC00 && codePoint <= 0xD7A3)
            || (codePoint >= 0xF900 && codePoint <= 0xFAFF)
            || (codePoint >= 0xFE10 && codePoint <= 0xFE19)
            || (codePoint >= 0xFE30 && codePoint <= 0xFE6F)
            || (codePoint >= 0xFF00 && codePoint <= 0xFF60)
            || (codePoint >= 0xFFE0 && codePoint <= 0xFFE6)
            || (codePoint >= 0x1F000 && codePoint <= 0x1FAFF)
            || (codePoint >= 0x20000 && codePoint <= 0x3FFFD);
    }

    function _lineCount(bytes memory data)
        private
        pure
        returns (uint256 lines)
    {
        uint256 cursor = _skipInlineWhitespace(data, 0);

        while (cursor < data.length && lines < MAX_LINES) {
            cursor = _nextLineStart(data, _wordLineEnd(data, cursor));
            ++lines;
        }

        if (lines == 0) lines = 1;
    }

    function _wordLineEnd(bytes memory data, uint256 start)
        private
        pure
        returns (uint256 cursor)
    {
        cursor = start;
        uint256 lastWhitespace = type(uint256).max;
        uint256 visualUnits;

        while (cursor < data.length) {
            if (_isLineBreak(data[cursor])) return cursor;
            if (_isInlineWhitespace(data[cursor])) {
                lastWhitespace = cursor;
            }

            uint256 nextVisualUnits = _visualUnitsAt(data, cursor);
            if (
                nextVisualUnits != 0
                    && visualUnits + nextVisualUnits > MAX_LINE_UNITS
            ) break;

            cursor += _utf8SequenceLength(uint8(data[cursor]));
            visualUnits += nextVisualUnits;
        }

        if (cursor == data.length || lastWhitespace == type(uint256).max) {
            return cursor;
        }
        return lastWhitespace;
    }

    function _nextLineStart(bytes memory data, uint256 cursor)
        private
        pure
        returns (uint256)
    {
        if (cursor < data.length && _isLineBreak(data[cursor])) {
            if (
                data[cursor] == 0x0D &&
                cursor + 1 < data.length &&
                data[cursor + 1] == 0x0A
            ) {
                return cursor + 2;
            }
            return cursor + 1;
        }
        return _skipInlineWhitespace(data, cursor);
    }

    function _skipInlineWhitespace(bytes memory data, uint256 cursor)
        private
        pure
        returns (uint256)
    {
        while (
            cursor < data.length &&
            _isInlineWhitespace(data[cursor])
        ) {
            ++cursor;
        }
        return cursor;
    }

    function _skipWhitespace(bytes memory data, uint256 cursor)
        private
        pure
        returns (uint256)
    {
        while (cursor < data.length && _isWhitespace(data[cursor])) {
            ++cursor;
        }
        return cursor;
    }

    function _isWhitespace(bytes1 value) private pure returns (bool) {
        return _isInlineWhitespace(value) || _isLineBreak(value);
    }

    function _isInlineWhitespace(bytes1 value)
        private
        pure
        returns (bool)
    {
        return value == 0x20 || value == 0x09;
    }

    function _isLineBreak(bytes1 value) private pure returns (bool) {
        return value == 0x0A || value == 0x0D;
    }

    function _containsVisibleCharacter(bytes memory data)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < data.length; ++i) {
            if (uint8(data[i]) > 0x20) return true;
        }
        return false;
    }

    function _utf8SequenceLength(uint8 firstByte)
        private
        pure
        returns (uint256)
    {
        if (firstByte < 0x80) return 1;
        if (firstByte < 0xE0) return 2;
        if (firstByte < 0xF0) return 3;
        return 4;
    }

    function _isValidUTF8(bytes memory data) private pure returns (bool) {
        uint256 i;
        while (i < data.length) {
            uint8 a = uint8(data[i]);

            if (a < 0x80) {
                ++i;
                continue;
            }

            if (a >= 0xC2 && a <= 0xDF) {
                if (i + 1 >= data.length || !_continuation(data[i + 1])) {
                    return false;
                }
                i += 2;
                continue;
            }

            if (a >= 0xE0 && a <= 0xEF) {
                if (i + 2 >= data.length) return false;
                uint8 b = uint8(data[i + 1]);
                if (
                    !_continuation(data[i + 1])
                        || !_continuation(data[i + 2])
                        || (a == 0xE0 && b < 0xA0)
                        || (a == 0xED && b >= 0xA0)
                ) return false;
                i += 3;
                continue;
            }

            if (a >= 0xF0 && a <= 0xF4) {
                if (i + 3 >= data.length) return false;
                uint8 b = uint8(data[i + 1]);
                if (
                    !_continuation(data[i + 1])
                        || !_continuation(data[i + 2])
                        || !_continuation(data[i + 3])
                        || (a == 0xF0 && b < 0x90)
                        || (a == 0xF4 && b >= 0x90)
                ) return false;
                i += 4;
                continue;
            }

            return false;
        }
        return true;
    }

    function _continuation(bytes1 value) private pure returns (bool) {
        uint8 b = uint8(value);
        return b >= 0x80 && b <= 0xBF;
    }

    function _slice(bytes memory data, uint256 start, uint256 end)
        private
        pure
        returns (string memory)
    {
        bytes memory part = new bytes(end - start);
        for (uint256 i; i < part.length; ++i) {
            part[i] = data[start + i];
        }
        return string(part);
    }

    function _escapeXML(string memory value)
        private
        pure
        returns (string memory)
    {
        bytes memory input = bytes(value);
        bytes memory output = new bytes(input.length * 5);
        uint256 j;

        for (uint256 i; i < input.length; ++i) {
            bytes1 c = input[i];
            if (c == "&") {
                output[j++] = "&";
                output[j++] = "a";
                output[j++] = "m";
                output[j++] = "p";
                output[j++] = ";";
            } else if (c == "<") {
                output[j++] = "&";
                output[j++] = "l";
                output[j++] = "t";
                output[j++] = ";";
            } else if (c == ">") {
                output[j++] = "&";
                output[j++] = "g";
                output[j++] = "t";
                output[j++] = ";";
            } else if (uint8(c) < 0x20) {
                output[j++] = " ";
            } else {
                output[j++] = c;
            }
        }

        assembly ("memory-safe") {
            mstore(output, j)
        }
        return string(output);
    }

    function _escapeJSON(string memory value)
        private
        pure
        returns (string memory)
    {
        bytes memory input = bytes(value);
        bytes memory output = new bytes(input.length * 2);
        uint256 j;

        for (uint256 i; i < input.length; ++i) {
            bytes1 c = input[i];
            if (c == '"' || c == "\\") {
                output[j++] = "\\";
                output[j++] = c;
            } else if (c == "\n") {
                output[j++] = "\\";
                output[j++] = "n";
            } else if (c == "\r") {
                output[j++] = "\\";
                output[j++] = "r";
            } else if (c == "\t") {
                output[j++] = "\\";
                output[j++] = "t";
            } else if (uint8(c) < 0x20) {
                output[j++] = " ";
            } else {
                output[j++] = c;
            }
        }

        assembly ("memory-safe") {
            mstore(output, j)
        }
        return string(output);
    }
}

/// @dev Optional read-only source for a verified display name.
interface IENSNameResolver {
    /// @notice Returns the name currently linked to an account.
    function nameOf(
        address account
    ) external view returns (string memory name);
}
