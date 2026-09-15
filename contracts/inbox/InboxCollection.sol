// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IEchoerDataStore} from "./../interface/IEchoerDataStore.sol";
import {IOwnable} from "./../interface/IOwnable.sol";
import {IEchoer} from "./../interface/IEchoer.sol";
import {IEchoerWall} from "./../interface/IEchoerWall.sol";
import {IInboxCollectionExecutor} from "./../interface/IInboxCollectionExecutor.sol";
import {IInboxCollectionExecutorRenderer} from "./../interface/IInboxCollectionExecutorRenderer.sol";
import {EchoerInfoLib} from "./../library/EchoerInfoLib.sol";
import {EchoerInboxRenderer} from "./InboxCollectionRenderer.sol";

/*
 *                 E C H O E R   I N B O X
 *
 *        WHAT IS THIS?
 *
 *        Echoer gives every address a public Wall.
 *        Other people can leave messages, called Echoes, on your Wall.
 *        Your Wall may turn an incoming message into an NFT.
 *        The NFT is minted to the address that owns the Wall.
 *
 *        This is why an "Echoer Inbox" NFT may appear in your wallet:
 *        it is a receipt of a message someone sent to your Wall.
 *
 *
 *        HOW DOES THIS INBOX WORK?
 *
 *        Each NFT keeps the Echo that created it connected to its
 *        original sender, message, and time.
 *
 *        An Inbox can belong to a wallet or contract address.
 *        It can hold personal messages, replies, or public discussion
 *        around that address. All messages are public.
 *
 *        People may continue the conversation by visiting a sender's
 *        Wall and Echoing back.
 *
 *        Some Echoes may include custom NFT artwork, allowing a sender
 *        to leave more than a text message on the receiving Wall.
 *        When attached, that custom artwork is shown by default. The
 *        original Echo receipt remains stored and can still be selected.
 *
 *        When the Wall is controlled by an owner, that owner may change
 *        its configuration, choose another collection, and manage NFTs
 *        that the address is able to control.
 *
 *        For some addresses, especially contracts, received NFTs may
 *        simply remain there permanently if the address has no way to
 *        transfer or burn them.
 *
 *        Changing the Wall's collection does not erase the public Echoes
 *        that were already sent to that address.
 *
 *        If an Inbox NFT is sold, it announces a 10% ERC-2981 royalty
 *        for its original sender.
 *
 *
 *        WALL OWNER TOOLS
 *
 *        The Wall owner may choose renderers, choose how Inbox NFTs
 *        are displayed, and publish collection information through
 *        contractURI.
 *
 *        The Wall owner may also withdraw ETH held by this collection.
 *
 *
 *        FOR APPS AND BUILDERS
 *
 *        To attach custom NFT metadata before sending:
 *          1. Call encodeCustomURIData here.
 *          2. Pass the returned bytes as `data` to echoToWithData.
 *          3. Check the same bytes with tokenURIPreview if needed.
 *
 *        Custom metadata may use JSON data, IPFS, Arweave, or BTFS.
 *        Changeable HTTP and HTTPS links are rejected.
 *
 *        Other optional app data is reported by event and is not stored.
 *
 *        Metadata is intentionally not frozen because the Wall owner
 *        may still select renderers and artwork views.
 *
 *        Use echoData to read the original message and optional custom URI.
 *
 *
 *        INBOX ABILITIES
 *
 *        Receive   Turn incoming Echoes into collectible message receipts.
 *        Read      Recover the original sender, message, time, and value.
 *        Display   Show the Echo receipt or attached custom artwork.
 *        Style     Choose renderers used for receipt-style NFTs.
 *        Describe  Publish collection information through contractURI.
 *        Reward    Announce a 10% ERC-2981 royalty to the original sender.
 *        Burn      Burn one or several owned or approved NFTs at once.
 */

/// @title Echoer Inbox Collection
/// @notice A Wall-owned, transferable NFT collection for incoming Echoes.
/// @dev Only the bound Wall mints. The Wall owner controls renderers and held
/// ETH. A broken custom renderer falls back to the built-in renderer.
contract InboxCollection is
    ERC721,
    IInboxCollectionExecutor,
    IERC4906,
    IERC2981
{
    /// @notice Stored data for one incoming Echo.
    /// @dev `bytes21` (21 bytes) plus `uint88` (11 bytes) occupy one slot.
    struct InboxEcho {
        bytes21 dataRef;
        uint88 value;
    }

    /// @notice Message data returned for one Inbox NFT.
    struct EchoData {
        uint32 messageId;
        uint40 sentAt;
        address sender;
        uint256 value;
        string message;
        string customURI;
    }

    /// @notice Shared store for incoming Echo message text.
    address public constant ECHOER_DATA_STORE = 0x9694e36F48149A3B4E7b6b9d8033eb764501e323;
    uint256 private constant MAX_DATA_STORE_STRING_BYTES = 24_575;

    /// @notice Royalty paid to every Inbox NFT's original sender: 10%.
    uint96 public constant ROYALTY_BPS = 1_000;
    uint96 private constant BPS_DENOMINATOR = 10_000;

    /// @dev ERC-4906 uses this fixed interface ID for metadata update events.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    /// @dev ERC-7572 identifies the collection-level `contractURI()` function.
    bytes4 private constant ERC7572_INTERFACE_ID = 0xe8a3d485;

    /// @notice Data tag used by `encodeCustomURIData`.
    bytes4 public constant INBOX_CUSTOM_URI_DATA_TAG =
        bytes4(keccak256("Echoer.Default.Inbox.Collection.CustomURIData"));

    /// @dev The lowest token-ID bit marks an available custom URI.
    uint256 private constant CUSTOM_URI_FLAG = 1;

    uint8 private constant DISPLAY_MESSAGE = 1;
    uint8 private constant DISPLAY_CUSTOM_URI = 2;

    enum InboxDataKind {
        None,
        CustomURI,
        Other,
        Invalid
    }

    /// @dev Shared renderer used until the Wall owner chooses another one.
    IInboxCollectionExecutorRenderer private immutable _defaultRenderer;

    /// @dev Per-collection renderer override. Zero means use the default.
    IInboxCollectionExecutorRenderer private _rendererOverride;

    /// @notice Wall allowed to mint for this collection.
    address public wall;

    /// @dev One packed message-reference/value slot per token ID.
    mapping(uint256 tokenId => InboxEcho data) private _inboxEchoes;

    /// @dev Shared-store reference for optional ERC-7572 collection metadata.
    bytes21 private _contractURIRef;

    /// @dev True only when regular Inbox receipts are the collection default.
    /// Zero-initialized clone storage therefore defaults to custom metadata.
    bool private _showMessageByDefault;

    /// @dev Zero follows the default; one shows the receipt; two shows the URI.
    mapping(uint256 tokenId => uint8 mode) private _tokenDisplayModes;

    /// @notice Emitted when the Wall owner changes the metadata renderer.
    event RendererChanged(address indexed renderer);

    /// @notice Emitted when a token-specific renderer is set or cleared.
    /// @dev A zero renderer means the token uses the collection renderer.
    event TokenRendererChanged(
        uint256 indexed tokenId,
        address indexed renderer
    );

    /// @notice Emitted when the Inbox's default metadata view changes.
    event DefaultCustomURIViewChanged(bool showCustomURI);

    /// @notice Emitted when one token's metadata view changes.
    event TokenCustomURIViewChanged(
        uint256 indexed tokenId,
        bool showCustomURI,
        bool followsDefault
    );

    /// @notice Associates unrecognized application data with one Inbox token.
    event EchoInData(uint256 indexed tokenId, bytes data);

    /// @notice Emitted when ETH is withdrawn from this collection.
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice ERC-7572 signal that collection-level metadata changed.
    event ContractURIUpdated();

    /// @dev Deploys and verifies the built-in renderer, then locks this template.
    constructor() ERC721("Echoer Inbox", "ECHO-IN") {
        address _renderer = address(new EchoerInboxRenderer());
        if (
            !ERC165Checker.supportsInterface(
                _renderer,
                type(IInboxCollectionExecutorRenderer).interfaceId
            )
        ) {
            revert("Invalid renderer");
        }
        _defaultRenderer = IInboxCollectionExecutorRenderer(_renderer);

        // Lock the implementation while leaving every clone's Wall slot zero.
        wall = address(1);
    }

    /// @notice Binds this collection to its Wall once.
    /// @dev The first caller becomes the Wall; later calls revert.
    function initialize() external {
        if (wall != address(0)) revert("Already initialized");
        wall = msg.sender;
    }

    /// @dev Allows calls only from the bound Wall.
    modifier onlyWall() {
        if (msg.sender != wall) revert("Only Wall");
        _;
    }

    /// @dev Allows calls only from the current Wall owner.
    modifier onlyWallOwner() {
        address currentOwner = _wallOwner();
        bool authorized = msg.sender == currentOwner;

        // If the wall owner is a contract, accept its owner as well.
        if (!authorized && currentOwner.code.length != 0) {
            try IOwnable(currentOwner).owner() returns (address contractOwner) {
                authorized = msg.sender == contractOwner;
            } catch {
                authorized = false;
            }
        }

        if (!authorized) revert("Only Wall Owner");
        _;
    }

    /// @dev Allows only the current owner of one Inbox NFT.
    modifier onlyTokenOwner(uint256 tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert("Only NFT Owner");
        _;
    }

    /// @notice Reports the ERC-165 interfaces supported by this collection.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721, IERC165) returns (bool) {
        return
            interfaceId == type(IInboxCollectionExecutor).interfaceId
                || interfaceId == type(IERC2981).interfaceId
                || interfaceId == ERC4906_INTERFACE_ID
                || interfaceId == ERC7572_INTERFACE_ID
                || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the current collection owner (the Wall owner).
    function owner() external view returns (address) {
        return _wallOwner();
    }

    /// @notice Returns the ERC-2981 royalty owed to a token's original sender.
    /// @dev The 10% royalty applies to regular and custom-URI Inbox NFTs.
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        _requireOwned(tokenId);
        (receiver, , , ) = tokenParts(tokenId);
        royaltyAmount = Math.mulDiv(
            salePrice,
            ROYALTY_BPS,
            BPS_DENOMINATOR
        );
    }

    /// @notice Returns ERC-7572 metadata for this Inbox collection.
    /// @dev Returns an empty string until the Wall owner sets a URI.
    function contractURI() external view returns (string memory) {
        if (_contractURIRef == bytes21(0)) return "";
        return IEchoerDataStore(ECHOER_DATA_STORE).stringOf(_contractURIRef);
    }

    /// @notice Returns `Echoer Inbox Collection Of <owner name>`.
    function name() public view override returns (string memory) {
        return string.concat(
            "Echoer Inbox Collection Of ",
            _wallOwnerName()
        );
    }

    /// @notice Returns `ECHO-IN-<owner name>`.
    function symbol() public view override returns (string memory) {
        return string.concat("ECHO-IN-", _wallOwnerName());
    }

    /// @notice Returns the collection renderer used without a token override.
    function renderer() public view returns (address) {
        return address(_activeRenderer());
    }

    /// @notice Returns the renderer configured specifically for a token.
    /// @dev Returns zero when the token uses the collection renderer.
    function tokenRenderer(
        uint256 tokenId
    ) public view returns (address) {
        _requireOwned(tokenId);
        return address(_tokenRendererOverrides[tokenId]);
    }

    /// @notice Returns the effective renderer used for a token.
    /// @dev Returns zero while the token is showing its custom URI.
    function rendererOf(
        uint256 tokenId
    ) public view returns (address) {
        _requireOwned(tokenId);
        if (_showsCustomURI(tokenId)) return address(0);
        return address(_activeRenderer(tokenId));
    }

    /// @notice Mints an incoming Echo as a transferable Inbox NFT.
    /// @dev Only the bound Wall can call. `owner_` receives the NFT, `from_`
    /// identifies the sender, and `fromInfo` supplies the sender's message ID.
    function onEchoInFromWall(
        address owner_,
        address from_,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message
    ) external payable onlyWall {
        _mintInbox(owner_, from_, fromInfo, echoValue, message, "", false);
    }

    /// @notice Mints an incoming Echo with optional app data or a custom URI.
    /// @dev A recognized custom URI is stored. Other non-empty data is emitted.
    function onEchoInWithDataFromWall(
        address owner_,
        address from_,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message,
        bytes calldata data
    ) external payable onlyWall {
        (
            InboxDataKind kind,
            string memory customURI,
            string memory reason
        ) = _decodeInboxData(data);

        if (kind == InboxDataKind.Invalid) revert(reason);

        (uint256 tokenId, ) = _mintInbox(
            owner_,
            from_,
            fromInfo,
            echoValue,
            message,
            customURI,
            kind == InboxDataKind.CustomURI
        );

        if (kind == InboxDataKind.Other) {
            emit EchoInData(tokenId, data);
        }
    }

    /// @notice Encodes an immutable metadata URI for one Inbox NFT.
    /// @dev The original message is also stored and can be selected as the view.
    function encodeCustomURIData(
        string calldata customURI
    ) external pure returns (bytes memory) {
        if (bytes(customURI).length == 0) revert("Custom URI is empty");
        if (bytes(customURI).length > MAX_DATA_STORE_STRING_BYTES) {
            revert("Custom URI exceeds DataStore maximum length");
        }
        if (!_isAllowedCustomURI(customURI)) {
            revert("Unsupported custom URI");
        }
        return abi.encodePacked(INBOX_CUSTOM_URI_DATA_TAG, bytes(customURI));
    }

    /// @notice Sets or clears this collection's ERC-7572 metadata URI.
    /// @dev Only the current Wall owner can call. Empty text clears the URI.
    function setContractURI(
        string calldata newContractURI
    ) external onlyWallOwner {
        if (bytes(newContractURI).length == 0) {
            delete _contractURIRef;
        } else {
            if (bytes(newContractURI).length > MAX_DATA_STORE_STRING_BYTES) {
                revert("Contract URI exceeds DataStore maximum length");
            }
            if (!_isAllowedCustomURI(newContractURI)) {
                revert("Unsupported contract URI");
            }

            _contractURIRef = IEchoerDataStore(ECHOER_DATA_STORE).storeString(
                newContractURI
            );
        }

        emit ContractURIUpdated();
    }

    /// @notice Whether custom-URI tokens show their custom metadata by default.
    /// @dev Returns true from zero-initialized clone storage without initialize.
    function showCustomURIByDefault() public view returns (bool) {
        return !_showMessageByDefault;
    }

    /// @notice Chooses the default view for NFTs that have a custom URI.
    /// @dev Custom metadata is the initial default. False selects regular
    /// Inbox receipts. Token-specific choices have priority.
    function setShowCustomURIByDefault(
        bool showCustomURI
    ) external onlyWallOwner {
        _showMessageByDefault = !showCustomURI;
        emit DefaultCustomURIViewChanged(showCustomURI);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Chooses the regular receipt or custom URI for one Inbox NFT.
    /// @dev Only its current NFT owner can choose. This overrides the default
    /// until the token choice is cleared.
    function setTokenShowCustomURI(
        uint256 tokenId,
        bool showCustomURI
    ) external onlyTokenOwner(tokenId) {
        if (!_hasCustomURI(tokenId)) revert("Token has no custom URI");

        _tokenDisplayModes[tokenId] = showCustomURI
            ? DISPLAY_CUSTOM_URI
            : DISPLAY_MESSAGE;

        emit TokenCustomURIViewChanged(tokenId, showCustomURI, false);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Makes one Inbox NFT follow the collection default again.
    /// @dev Only its current NFT owner can clear the token choice.
    function clearTokenDisplayChoice(
        uint256 tokenId
    ) external onlyTokenOwner(tokenId) {
        if (!_hasCustomURI(tokenId)) revert("Token has no custom URI");

        delete _tokenDisplayModes[tokenId];
        emit TokenCustomURIViewChanged(
            tokenId,
            showCustomURIByDefault(),
            true
        );
        emit MetadataUpdate(tokenId);
    }

    /// @notice Sets the collection-wide metadata renderer.
    /// @dev Only the current Wall owner can call. The renderer must advertise
    /// `IInboxCollectionExecutorRenderer` through ERC-165.
    function setRenderer(
        address renderer_
    ) external onlyWallOwner {
        if (
            !ERC165Checker.supportsInterface(
                renderer_,
                type(IInboxCollectionExecutorRenderer).interfaceId
            )
        ) {
            revert("Invalid renderer");
        }

        _rendererOverride = IInboxCollectionExecutorRenderer(renderer_);
        emit RendererChanged(renderer_);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Sets or clears the metadata renderer for one Inbox NFT.
    /// @dev The token renderer has priority over the collection renderer.
    /// Pass zero to clear it and restore collection-level rendering.
    function setTokenRenderer(
        uint256 tokenId,
        address renderer_
    ) external onlyWallOwner {
        _requireOwned(tokenId);
        if (
            renderer_ != address(0)
                && !ERC165Checker.supportsInterface(
                    renderer_,
                    type(IInboxCollectionExecutorRenderer).interfaceId
                )
        ) {
            revert("Invalid renderer");
        }

        _tokenRendererOverrides[tokenId] =
            IInboxCollectionExecutorRenderer(renderer_);
        emit TokenRendererChanged(tokenId, renderer_);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Withdraws ETH held by this Inbox collection.
    /// @dev Only the current Wall owner can call.
    function withdraw(
        address payable to,
        uint256 amount
    ) external onlyWallOwner {
        if (to == address(0)) revert("Invalid recipient");
        if (address(this).balance < amount) revert("Insufficient balance");

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert("Transfer failed");

        emit Withdrawn(to, amount);
    }

    /// @notice Permanently burns one or more Inbox NFTs.
    /// @dev The caller must own or be approved for every listed token.
    function burn(
        uint256[] calldata tokenIds
    ) external {
        uint256 length = tokenIds.length;
        if (length == 0) revert("No tokens to burn");

        for (uint256 i; i < length; ) {
            uint256 tokenId = tokenIds[i];
            address tokenOwner = _requireOwned(tokenId);
            if (!_isAuthorized(tokenOwner, msg.sender, tokenId)) {
                revert("Not NFT owner or approved");
            }

            _burn(tokenId);
            delete _inboxEchoes[tokenId];
            delete _tokenDisplayModes[tokenId];
            delete _tokenRendererOverrides[tokenId];

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the effective data for an existing Inbox NFT.
    function echoData(
        uint256 tokenId
    ) external view returns (EchoData memory data) {
        _requireOwned(tokenId);
        (
            address sender,
            uint32 messageId,
            uint40 sentAt,
            bool hasCustomURI
        ) = tokenParts(tokenId);
        InboxEcho memory stored = _inboxEchoes[tokenId];

        string memory storedData = IEchoerDataStore(ECHOER_DATA_STORE)
            .stringOf(stored.dataRef);
        string memory message;
        string memory customURI;

        if (hasCustomURI) {
            (message, customURI) = abi.decode(
                bytes(storedData),
                (string, string)
            );
        } else {
            message = storedData;
        }

        data = EchoData({
            messageId: messageId,
            sentAt: sentAt,
            sender: sender,
            value: uint256(stored.value),
            message: message,
            customURI: customURI
        });
    }

    /// @notice Reads all immutable fields packed inside a token ID.
    /// @dev Layout: `[messageId:32][sentAt:40][sender:160][hasCustomURI:1]`.
    /// The sender and message ID identify the original Echo in this collection.
    function tokenParts(
        uint256 tokenId
    ) public pure returns (
        address sender,
        uint32 messageId,
        uint40 sentAt,
        bool hasCustomURI
    ) {
        messageId = uint32(tokenId >> 201);
        sentAt = uint40(tokenId >> 161);
        sender = address(uint160(tokenId >> 1));
        hasCustomURI = _hasCustomURI(tokenId);
    }

    /// @inheritdoc ERC721
    /// @dev Returns attached custom metadata by default. An explicit token or
    /// collection choice can instead render the original Echo receipt.
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);

        (
            address sender,
            uint32 messageId,
            uint40 sentAt,
            bool hasCustomURI
        ) = tokenParts(tokenId);

        InboxEcho memory stored = _inboxEchoes[tokenId];
        string memory storedData = IEchoerDataStore(ECHOER_DATA_STORE)
            .stringOf(stored.dataRef);
        string memory message = storedData;

        if (hasCustomURI) {
            string memory customURI;
            (message, customURI) = abi.decode(
                bytes(storedData),
                (string, string)
            );

            if (_showsCustomURI(tokenId)) return customURI;
        }

        IInboxCollectionExecutorRenderer.TokenURIInput memory input =
            IInboxCollectionExecutorRenderer.TokenURIInput({
                echoerCore: echoerCore(),
                collection: address(this),
                sender: sender,
                receiver: _wallOwner(),
                nftOwner: ownerOf(tokenId),
                tokenId: tokenId,
                preferENS: preferENSName,
                echo: IInboxCollectionExecutorRenderer.MessageData({
                    messageId: messageId,
                    sentAt: sentAt,
                    value: uint256(stored.value),
                    message: message
                })
            });

        return _renderTokenURI(_activeRenderer(tokenId), input);
    }

    /// @notice Previews an Inbox NFT before the message is sent or token is minted.
    /// @dev Uses the current Wall owner as the expected initial NFT owner.
    function tokenURIPreview(
        address sender,
        uint32 previewMessageId,
        uint256 value,
        string calldata message,
        bytes calldata data
    ) external view returns (string memory) {
        if (value > type(uint88).max) {
            revert("Value exceeds Inbox storage maximum");
        }
        if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
            revert("Message exceeds DataStore maximum length");
        }

        (
            InboxDataKind kind,
            string memory customURI,
            string memory reason
        ) = _decodeInboxData(data);

        if (kind == InboxDataKind.Invalid) revert(reason);
        if (kind == InboxDataKind.CustomURI) {
            if (!_customDataFits(message, customURI)) {
                revert("Message and custom URI exceed DataStore maximum length");
            }
            if (showCustomURIByDefault()) return customURI;
        }

        address receiver = _wallOwner();

        IInboxCollectionExecutorRenderer.TokenURIInput memory input =
            IInboxCollectionExecutorRenderer.TokenURIInput({
                echoerCore: echoerCore(),
                collection: address(this),
                sender: sender,
                receiver: receiver,

                // Inbox NFTs are expected to be initially owned by the receiver.
                nftOwner: receiver,

                // A preview has no minted token ID.
                tokenId: 0,

                preferENS: preferENSName,

                echo: IInboxCollectionExecutorRenderer.MessageData({
                    messageId: previewMessageId,
                    sentAt: uint40(block.timestamp),
                    value: value,
                    message: message
                })
            });

        return _renderTokenURI(_activeRenderer(), input);
    }

    function _mintInbox(
        address owner_,
        address from_,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message,
        string memory customURI,
        bool hasCustomURI
    ) private returns (uint256 tokenId, uint32 messageId) {
        if (echoValue > type(uint88).max) {
            revert("Value exceeds Inbox storage maximum");
        }
        if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
            revert("Message exceeds DataStore maximum length");
        }

        (messageId, ) = EchoerInfoLib.echoCounts(fromInfo);

        bytes21 dataRef;
        if (hasCustomURI) {
            if (!_customDataFits(message, customURI)) {
                revert("Message and custom URI exceed DataStore maximum length");
            }

            dataRef = IEchoerDataStore(ECHOER_DATA_STORE).storeString(
                string(abi.encode(message, customURI))
            );
        } else {
            dataRef = IEchoerDataStore(ECHOER_DATA_STORE).storeString(
                message
            );
        }

        uint40 sentAt = uint40(block.timestamp);
        tokenId = _packTokenId(
            from_,
            messageId,
            sentAt,
            hasCustomURI
        );

        _inboxEchoes[tokenId] = InboxEcho({
            dataRef: dataRef,
            value: uint88(echoValue)
        });

        _mint(owner_, tokenId);
    }

    function _packTokenId(
        address sender,
        uint32 messageId,
        uint40 sentAt,
        bool hasCustomURI
    ) private pure returns (uint256 tokenId) {
        tokenId = (uint256(messageId) << 201)
            | (uint256(sentAt) << 161)
            | (uint256(uint160(sender)) << 1)
            | (hasCustomURI ? CUSTOM_URI_FLAG : 0);
    }

    function _decodeInboxData(
        bytes calldata data
    ) private pure returns (
        InboxDataKind kind,
        string memory customURI,
        string memory reason
    ) {
        if (data.length == 0) {
            return (InboxDataKind.None, "", "");
        }
        if (data.length < 4) {
            return (InboxDataKind.Other, "", "");
        }

        bytes4 tag;
        assembly ("memory-safe") {
            tag := calldataload(data.offset)
        }

        if (tag != INBOX_CUSTOM_URI_DATA_TAG) {
            return (InboxDataKind.Other, "", "");
        }
        if (data.length == 4) {
            return (InboxDataKind.Invalid, "", "Custom URI is empty");
        }
        if (data.length - 4 > MAX_DATA_STORE_STRING_BYTES) {
            return (
                InboxDataKind.Invalid,
                "",
                "Custom URI exceeds DataStore maximum length"
            );
        }

        customURI = string(data[4:]);
        if (!_isAllowedCustomURI(customURI)) {
            return (InboxDataKind.Invalid, "", "Unsupported custom URI");
        }

        return (InboxDataKind.CustomURI, customURI, "");
    }

    function _hasCustomURI(
        uint256 tokenId
    ) private pure returns (bool) {
        return (tokenId & CUSTOM_URI_FLAG) != 0;
    }

    function _showsCustomURI(
        uint256 tokenId
    ) private view returns (bool) {
        if (!_hasCustomURI(tokenId)) return false;

        uint8 mode = _tokenDisplayModes[tokenId];
        if (mode == DISPLAY_CUSTOM_URI) return true;
        if (mode == DISPLAY_MESSAGE) return false;
        return showCustomURIByDefault();
    }

    function _customDataFits(
        string calldata message,
        string memory customURI
    ) private pure returns (bool) {
        uint256 encodedLength = 128
            + _paddedLength(bytes(message).length)
            + _paddedLength(bytes(customURI).length);
        return encodedLength <= MAX_DATA_STORE_STRING_BYTES;
    }

    function _paddedLength(
        uint256 length
    ) private pure returns (uint256) {
        return (length + 31) & ~uint256(31);
    }

    function _isAllowedCustomURI(
        string memory customURI
    ) private pure returns (bool) {
        bytes memory uri = bytes(customURI);
        return
            _startsWith(uri, bytes("data:application/json;base64,"))
                || _startsWith(uri, bytes("ipfs://"))
                || _startsWith(uri, bytes("ar://"))
                || _startsWith(uri, bytes("btfs://"))
                || _startsWith(uri, bytes("ipns://"))
                || _startsWith(uri, bytes("bzz://"));
    }

    function _startsWith(
        bytes memory value,
        bytes memory prefix
    ) private pure returns (bool) {
        // A URI must contain at least one byte after its scheme.
        if (value.length <= prefix.length) return false;

        for (uint256 i; i < prefix.length; ++i) {
            if (value[i] != prefix[i]) return false;
        }
        return true;
    }

    function _wallOwnerName() private view returns (string memory) {
        return IEchoer(echoerCore()).nameOf(_wallOwner());
    }

    function _wallOwner() private view returns (address) {
        return IEchoerWall(wall).owner();
    }

    function _activeRenderer()
        private
        view
        returns (IInboxCollectionExecutorRenderer)
    {
        if (address(_rendererOverride) != address(0)) {
            return _rendererOverride;
        }
        return _defaultRenderer;
    }

    function _activeRenderer(
        uint256 tokenId
    ) private view returns (IInboxCollectionExecutorRenderer) {
        IInboxCollectionExecutorRenderer tokenRenderer_ =
            _tokenRendererOverrides[tokenId];
        if (address(tokenRenderer_) != address(0)) {
            return tokenRenderer_;
        }
        return _activeRenderer();
    }

    /// @dev A broken optional renderer must not make existing metadata
    /// unavailable. The built-in renderer remains the final fallback.
    function _renderTokenURI(
        IInboxCollectionExecutorRenderer renderer_,
        IInboxCollectionExecutorRenderer.TokenURIInput memory input
    ) private view returns (string memory) {
        if (address(renderer_) == address(_defaultRenderer)) {
            return _defaultRenderer.tokenURI(input);
        }

        try renderer_.tokenURI(input) returns (string memory uri) {
            return uri;
        } catch {
            return _defaultRenderer.tokenURI(input);
        }
    }

    /// @notice Checks whether the Inbox can store the Echo, value, and data.
    function canEchoInFromWall(
        address _owner,
        address from,
        bytes32 fromInfo,
        uint256 value,
        bool forwardValueToExecutor,
        string calldata message,
        bytes calldata data
    ) external pure returns (
        bool allowed,
        string memory reason
    ) {
        _owner;
        from;
        fromInfo;
        forwardValueToExecutor;
        if (value > type(uint88).max) {
            return (false, "Value exceeds Inbox storage maximum");
        }
        if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
            return (false, "Message exceeds DataStore maximum length");
        }

        (
            InboxDataKind kind,
            string memory customURI,
            string memory dataReason
        ) = _decodeInboxData(data);

        if (kind == InboxDataKind.Invalid) {
            return (false, dataReason);
        }
        if (
            kind == InboxDataKind.CustomURI
                && !_customDataFits(message, customURI)
        ) {
            return (
                false,
                "Message and custom URI exceed DataStore maximum length"
            );
        }

        return (true, "");
    }

    /// @notice Whether NFT metadata should prefer usable ENS names.
    bool public preferENSName;

    /// @dev Per-token renderer override. Zero means use collection settings.
    mapping(uint256 tokenId => IInboxCollectionExecutorRenderer renderer_)
        private _tokenRendererOverrides;
    event ENSNamePreferenceChanged(bool preferENSName);

    /// @notice Chooses whether NFT metadata prefers ENS names.
    function setPreferENSName(
        bool prefer
    ) external onlyWallOwner {
        preferENSName = prefer;
        emit ENSNamePreferenceChanged(prefer);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Returns the Echoer Core connected through this collection's Wall.
    function echoerCore() public view returns (address) {
        return IEchoerWall(wall).echoerCore();
    }
}
