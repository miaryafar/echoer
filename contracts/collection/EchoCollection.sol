// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IEchoerDataStore} from "./../interface/IEchoerDataStore.sol";
import {IOwnable} from "./../interface/IOwnable.sol";

import {IEchoer} from "./../interface/IEchoer.sol";
import {IEchoerWall} from "./../interface/IEchoerWall.sol";
import {IEchoCollectionExecutor} from "./../interface/IEchoCollectionExecutor.sol";
import {IERC165, IEchoCollectionExecutorRenderer} from "./../interface/IEchoCollectionExecutorRenderer.sol";
import {EchoerInfoLib} from "./../library/EchoerInfoLib.sol";

import {EchoerEchoRenderer} from "./EchoCollectionRenderer.sol";

/*
 *                  E C H O   C O L L E C T I O N
 *
 *        WHAT ARE YOU LOOKING AT?
 *
 *        This is an NFT collection created through one Echoer Wall.
 *        An artist or collection maker can use their Wall to publish
 *        selected public Echoes as NFTs.
 *
 *        Only Echoes made through the connected Wall can become NFTs
 *        in this collection.
 *
 *        If you found one of these NFTs in a wallet or marketplace,
 *        it began as a public self-Echo made by the collection creator.
 *        The NFT therefore remains connected to its original public
 *        message and the time it was Echoed.
 *
 *        A creator may publish in two ways:
 *          - Turn the Echo itself into art using colors and renderers.
 *          - Attach immutable custom NFT metadata through an approved
 *            permanent-content URI.
 *
 *        Custom metadata bypasses Echo renderers and, once chosen for
 *        an NFT, cannot be replaced.
 *
 *        Rendered Echo NFTs remain visually customizable through the
 *        collection's supported colors and renderers.
 *
 *        The NFT may be transferred or burned, but its public Echo remains.
 *
 *        Every NFT announces a 10% ERC-2981 royalty for the current
 *        Wall owner. If Wall ownership changes, the royalty receiver
 *        changes with it.
 *
 *
 *        FOR APPS AND BUILDERS
 *
 *        To customize an NFT before Echoing:
 *          1. Call encodeColorData or encodeCustomURIData here.
 *          2. Pass the returned bytes as `data` to echoWithData.
 *          3. Check the same bytes with tokenURIPreview if needed.
 *
 *        Custom metadata may use JSON data, IPFS, Arweave, or BTFS.
 *        Changeable HTTP and HTTPS links are rejected.
 *
 *        Other optional app data is reported by event and is not stored.
 *        Regular Echo metadata may still change through supported colors
 *        and renderers.
 *
 *
 *        COLLECTION ABILITIES
 *
 *        Collect   Build an NFT collection from public self-Echoes.
 *        Publish   Turn selected self-Echoes into transferable NFTs.
 *        Read      Recover each NFT's original Echo message and time.
 *        Style     Choose collection or token colors and renderers.
 *        Artwork   Use a rendered Echo or immutable custom metadata.
 *        Describe  Publish collection information through contractURI.
 *        Reward    Announce a 10% ERC-2981 royalty to the Wall owner.
 *        Burn      Burn one or several owned or approved NFTs at once.
 */

/// @title Echoer Collection
/// @notice A Wall-owned, transferable NFT collection for Echo messages.
/// @dev Only the bound Wall mints. Message text uses EchoerDataStore. A broken
/// custom renderer falls back to the built-in renderer.
contract EchoCollection is
    ERC721,
    IEchoCollectionExecutor,
    IERC4906,
    IERC2981
{
    /// @notice Message, timestamp, and effective colors for one Echo NFT.
    /// @dev The message is resolved from the shared EchoerDataStore.
    struct EchoData {
        uint40 echoedAt;
        bytes3 backgroundColor;
        bytes3 foregroundColor;
        string message;
    }

    // ---------------------------------------------------------------------
    // Shared metadata services
    // ---------------------------------------------------------------------

    /// @notice Shared store for Echo message text.
    address public constant ECHOER_DATA_STORE = 0x9694e36F48149A3B4E7b6b9d8033eb764501e323;
    uint256 private constant MAX_DATA_STORE_STRING_BYTES = 24_575;

    /// @notice Royalty announced for every Echo NFT: 10%.
    uint96 public constant ROYALTY_BPS = 1_000;
    uint96 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Fixed interface IDs for metadata update and collection metadata.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;
    bytes4 private constant ERC7572_INTERFACE_ID = 0xe8a3d485;

    /// @notice Built-in colors used when no custom colors are set.
    bytes3 private constant DEFAULT_BACKGROUND_COLOR = 0xF3F0E8;
    bytes3 private constant DEFAULT_FOREGROUND_COLOR = 0x111111;

    /// @notice Data tag used by `encodeColorData`.
    bytes4 public constant ECHO_COLOR_DATA_TAG =
        bytes4(keccak256("Echoer.Default.Collection.ColorData"));

    /// @notice Data tag used by `encodeCustomURIData`.
    bytes4 public constant ECHO_CUSTOM_URI_DATA_TAG =
        bytes4(keccak256("Echoer.Default.Collection.CustomURIData"));

    /// @dev The lowest token-ID bit marks immutable custom metadata.
    uint256 private constant CUSTOM_URI_FLAG = 1;

    enum EchoDataKind {
        None,
        Colors,
        CustomURI,
        Unknown,
        Invalid
    }

    /// @dev Shared renderer used until the Wall owner selects another one.
    IEchoCollectionExecutorRenderer private immutable _defaultRenderer;

    /// @dev Per-collection renderer override. Zero means use the default.
    IEchoCollectionExecutorRenderer private _rendererOverride;

    /// @notice Wall allowed to mint for this collection.
    address public wall;

    // ---------------------------------------------------------------------
    // Color configuration
    // ---------------------------------------------------------------------

    /// @dev Marks an explicitly configured RGB pair.
    uint56 private constant COLOR_SET_FLAG = uint56(1) << 48;

    /// @dev Zero means the built-in colors apply.
    uint56 private _defaultColors;

    /// @dev Shared-store reference for optional ERC-7572 collection metadata.
    bytes21 private _contractURIRef;

    /// @dev Zero means this token uses the collection colors.
    mapping(uint256 tokenId => uint56 colors) private _tokenColors;

    /// @notice Emitted when collection-default colors change.
    event DefaultColorsChanged(
        bytes3 backgroundColor,
        bytes3 foregroundColor
    );

    /// @notice Emitted when an NFT's colors change or are cleared.
    event TokenColorsChanged(
        uint256 indexed tokenId,
        bytes3 backgroundColor,
        bytes3 foregroundColor
    );

    /// @notice Emitted when the Wall owner changes the metadata renderer.
    event RendererChanged(address indexed renderer);

    /// @notice Emitted when a token-specific renderer is set or cleared.
    /// @dev A zero renderer means the token uses the collection renderer.
    event TokenRendererChanged(
        uint256 indexed tokenId,
        address indexed renderer
    );

    /// @notice Emitted when optional Echo data is unknown and ignored.
    event UnrecognizedEchoData(uint32 indexed eID, bytes data);

    /// @notice ERC-7572 signal that collection-level metadata changed.
    event ContractURIUpdated();

    /// @dev Deploys and verifies the built-in renderer, then locks this template.
    constructor() ERC721("Echoer Echo", "ECHO") {
        address _renderer = address(new EchoerEchoRenderer());
        if (
            !ERC165Checker.supportsInterface(
                _renderer,
                type(IEchoCollectionExecutorRenderer).interfaceId
            )
        ) {
            revert("Invalid renderer");
        }
        _defaultRenderer = IEchoCollectionExecutorRenderer(_renderer);

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

    /// @notice Reports the ERC-165 interfaces supported by this collection.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721, IERC165) returns (bool) {
        return
            interfaceId == type(IEchoCollectionExecutor).interfaceId
                || interfaceId == type(IERC2981).interfaceId
                || interfaceId == ERC4906_INTERFACE_ID
                || interfaceId == ERC7572_INTERFACE_ID
                || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // ERC-721 identity
    // ---------------------------------------------------------------------

    /// @notice Returns the current collection owner (the Wall owner).
    /// @dev Read directly from the Wall, so ownership changes are reflected.
    function owner() external view returns (address) {
        return _wallOwner();
    }

    /// @notice Returns the ERC-2981 royalty owed to the current Wall owner.
    /// @dev The 10% royalty applies to every regular and custom Echo NFT.
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        _requireOwned(tokenId);
        receiver = _wallOwner();
        royaltyAmount = Math.mulDiv(
            salePrice,
            ROYALTY_BPS,
            BPS_DENOMINATOR
        );
    }

    /// @notice Returns ERC-7572 metadata for this Echo collection.
    /// @dev Returns an empty string until the Wall owner sets a URI.
    function contractURI() external view returns (string memory) {
        if (_contractURIRef == bytes21(0)) return "";
        return IEchoerDataStore(ECHOER_DATA_STORE).stringOf(_contractURIRef);
    }

    /// @notice Returns `Echoer Echo Collection Of <owner name>`.
    function name() public view override returns (string memory) {
        return string.concat("Echoer Echo Collection Of ", _wallOwnerName());
    }

    /// @notice Returns `ECHO-<owner name>`.
    function symbol() public view override returns (string memory) {
        return string.concat("ECHO-", _wallOwnerName());
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
    /// @dev Returns zero for custom-URI tokens because they bypass renderers.
    function rendererOf(
        uint256 tokenId
    ) public view returns (address) {
        _requireOwned(tokenId);
        if (_usesCustomURI(tokenId)) return address(0);
        return address(_activeRenderer(tokenId));
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    /// @notice Mints a message as a transferable Echo NFT.
    /// @dev Only the bound Wall can call. `_owner` receives the token and `eID`
    /// identifies the Echo in that owner's history.
    function onEchoFromWall(
        address _owner,
        uint32 eID,
        string calldata message
    ) external onlyWall {
        _mintEcho(_owner, eID, message, 0, "", false);
    }

    /// @notice Mints an Echo NFT with optional colors or a custom URI.
    /// @dev Only the bound Wall can call. Unknown `data` is ignored; use
    /// the encoding helpers to create recognized data.
    function onEchoWithDataFromWall(
        address _owner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    ) external onlyWall {
        (
            EchoDataKind kind,
            uint56 colors,
            string memory customURI,
            string memory reason
        ) = _decodeEchoData(data);

        if (kind == EchoDataKind.Invalid) revert(reason);

        if (kind == EchoDataKind.Unknown) {
            emit UnrecognizedEchoData(eID, data);
        }

        _mintEcho(
            _owner,
            eID,
            message,
            colors,
            customURI,
            kind == EchoDataKind.CustomURI
        );
    }

    /// @notice Encodes background and foreground colors for an Echo.
    /// @dev Pass the returned bytes as the callback `data` value.
    function encodeColorData(
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) external pure returns (bytes memory) {
        return abi.encodePacked(
            ECHO_COLOR_DATA_TAG,
            backgroundColor,
            foregroundColor
        );
    }

    /// @notice Encodes an immutable metadata URI for one Echo NFT.
    /// @dev Pass the returned bytes as the callback `data` value.
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
        return abi.encodePacked(ECHO_CUSTOM_URI_DATA_TAG, bytes(customURI));
    }

    function _mintEcho(
        address _owner,
        uint32 eID,
        string calldata message,
        uint56 colors,
        string memory customURI,
        bool usesCustomURI
    ) private {
        if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
            revert("Message exceeds DataStore maximum length");
        }

        bytes21 dataRef;
        if (usesCustomURI) {
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

        uint256 tokenId = _packTokenId(
            eID,
            dataRef,
            uint40(block.timestamp),
            usesCustomURI
        );

        if (colors != 0) {
            _tokenColors[tokenId] = colors;
            (
                bytes3 backgroundColor,
                bytes3 foregroundColor
            ) = _unpackColors(colors);
            emit TokenColorsChanged(
                tokenId,
                backgroundColor,
                foregroundColor
            );
        }

        _mint(_owner, tokenId);
    }

    // ---------------------------------------------------------------------
    // Burning
    // ---------------------------------------------------------------------

    /// @notice Permanently burns one or more Echo NFTs in one transaction.
    /// @dev The caller must own or be approved for every token. The whole
    /// transaction reverts if any token cannot be burned.
    function burn(
        uint256[] calldata tokenIds
    ) external {
        uint256 length = tokenIds.length;
        if (length == 0) revert("No tokens");

        for (uint256 i; i < length; ) {
            uint256 tokenId = tokenIds[i];
            address tokenOwner = _requireOwned(tokenId);
            if (!_isAuthorized(tokenOwner, msg.sender, tokenId)) {
                revert("Not NFT owner or approved");
            }

            _burn(tokenId);
            delete _tokenColors[tokenId];
            delete _tokenRendererOverrides[tokenId];

            unchecked {
                ++i;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Collection settings
    // ---------------------------------------------------------------------

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

    /// @notice Sets the collection-wide metadata renderer.
    /// @dev Only the current Wall owner can call. The address must be a
    /// contract implementing the Echo renderer interface.
    function setRenderer(address renderer_) external onlyWallOwner {
        require(_isSupportedRenderer(renderer_), "Invalid renderer");

        _rendererOverride = IEchoCollectionExecutorRenderer(renderer_);
        emit RendererChanged(renderer_);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Sets or clears the metadata renderer for one Echo NFT.
    /// @dev The token renderer has priority over the collection renderer.
    /// Pass zero to clear it. Custom-URI tokens cannot use renderers.
    function setTokenRenderer(
        uint256 tokenId,
        address renderer_
    ) external onlyWallOwner {
        _requireOwned(tokenId);
        if (_usesCustomURI(tokenId)) revert("Token uses custom URI");
        if (renderer_ != address(0) && !_isSupportedRenderer(renderer_)) {
            revert("Invalid renderer");
        }

        _tokenRendererOverrides[tokenId] =
            IEchoCollectionExecutorRenderer(renderer_);
        emit TokenRendererChanged(tokenId, renderer_);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Sets fallback colors for this collection.
    /// @dev Only the Wall owner can call. Use `(0, 0)` to restore built-in
    /// colors.
    function setDefaultColors(
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) external onlyWallOwner {
        _defaultColors = _packColors(
            backgroundColor,
            foregroundColor
        );
        emit DefaultColorsChanged(backgroundColor, foregroundColor);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Sets colors for one Echo NFT.
    /// @dev Only the current Wall owner can call. Use `(0, 0)` to use
    /// collection colors. Custom-URI tokens define their own presentation.
    function setTokenColors(
        uint256 tokenId,
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) external onlyWallOwner {
        _requireOwned(tokenId);
        if (_usesCustomURI(tokenId)) revert("Token uses custom URI");
        _tokenColors[tokenId] = _packColors(
            backgroundColor,
            foregroundColor
        );
        emit TokenColorsChanged(
            tokenId,
            backgroundColor,
            foregroundColor
        );
        emit MetadataUpdate(tokenId);
    }

    /// @notice Returns the collection's effective fallback colors.
    function defaultColors()
        external
        view
        returns (bytes3 backgroundColor, bytes3 foregroundColor)
    {
        return _colorsFromConfig(_defaultColors);
    }

    /// @notice Returns the effective colors for an Echo NFT.
    /// @dev Reverts if the token does not exist.
    function colorsOf(
        uint256 tokenId
    ) public view returns (
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) {
        _requireOwned(tokenId);
        return _effectiveColors(tokenId);
    }

    // ---------------------------------------------------------------------
    // Packed token data and rendering
    // ---------------------------------------------------------------------

    /// @notice Reads all immutable fields packed inside a token ID.
    /// @dev Layout: `[eID:32][timestamp:40][dataRef:168][customURI:1]`.
    function tokenParts(
        uint256 tokenId
    ) public pure returns (
        uint32 eID,
        bytes21 dataRef,
        uint40 echoedAt,
        bool customURI
    ) {
        eID = uint32(tokenId >> 209);
        echoedAt = uint40(tokenId >> 169);
        dataRef = bytes21(uint168(tokenId >> 1));
        customURI = _usesCustomURI(tokenId);
    }

    /// @notice Returns an Echo's message, timestamp, and effective colors.
    function echoData(
        uint256 tokenId
    ) external view returns (EchoData memory data) {
        _requireOwned(tokenId);
        (
            ,
            bytes21 dataRef,
            uint40 echoedAt,
            bool customURI
        ) = tokenParts(tokenId);
        (
            bytes3 backgroundColor,
            bytes3 foregroundColor
        ) = _effectiveColors(tokenId);

        string memory storedData = IEchoerDataStore(ECHOER_DATA_STORE)
            .stringOf(dataRef);
        string memory message;

        if (customURI) {
            (message, ) = abi.decode(
                bytes(storedData),
                (string, string)
            );
        } else {
            message = storedData;
        }

        data = EchoData({
            echoedAt: echoedAt,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            message: message
        });
    }

    /// @inheritdoc ERC721
    /// @dev Returns immutable custom metadata directly when present. Otherwise,
    /// supplies the Echo and display settings to the active renderer.
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);

        (
            uint32 eID,
            bytes21 dataRef,
            uint40 echoedAt,
            bool customURI
        ) = tokenParts(tokenId);

        string memory storedData = IEchoerDataStore(ECHOER_DATA_STORE)
            .stringOf(dataRef);

        if (customURI) {
            (, string memory uri) = abi.decode(
                bytes(storedData),
                (string, string)
            );
            return uri;
        }

        (
            bytes3 backgroundColor,
            bytes3 foregroundColor
        ) = _effectiveColors(tokenId);

        address wallOwner = _wallOwner();

        IEchoCollectionExecutorRenderer.TokenURIInput memory input =
            IEchoCollectionExecutorRenderer.TokenURIInput({
                echoerCore: echoerCore(),
                collection: address(this),
                echoer: wallOwner,
                tokenId: tokenId,
                backgroundColor: backgroundColor,
                foregroundColor: foregroundColor,
                preferENS: preferENSName,
                echo: IEchoCollectionExecutorRenderer.EchoData({
                    echoId: eID,
                    echoedAt: echoedAt,
                    message: storedData
                })
            });

        return _renderTokenURI(_activeRenderer(tokenId), input);
    }

    /// @notice Previews token metadata before publishing an Echo.
    /// @dev `data` follows the same rules as minting. The Echo ID is the Wall
    /// owner's current Echo count; it and the timestamp may change before minting.
    function tokenURIPreview(
        string calldata message,
        bytes calldata data,
        bool previewPreferENS
    ) external view returns (string memory) {
        if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
            revert("Message exceeds DataStore maximum length");
        }

        (
            uint56 colors,
            string memory customURI,
            bool usesCustomURI
        ) = _previewEchoData(message, data);
        if (usesCustomURI) return customURI;

        return _renderTokenURI(
            _activeRenderer(),
            _previewTokenURIInput(message, colors, previewPreferENS)
        );
    }

    function _previewEchoData(
        string calldata message,
        bytes calldata data
    ) private pure returns (
        uint56 colors,
        string memory customURI,
        bool usesCustomURI
    ) {
        (
            EchoDataKind kind,
            uint56 decodedColors,
            string memory decodedCustomURI,
            string memory reason
        ) = _decodeEchoData(data);

        if (kind == EchoDataKind.Invalid) revert(reason);

        usesCustomURI = kind == EchoDataKind.CustomURI;
        if (
            usesCustomURI
                && !_customDataFits(message, decodedCustomURI)
        ) {
            revert("Message and custom URI exceed DataStore maximum length");
        }

        return (decodedColors, decodedCustomURI, usesCustomURI);
    }

    function _previewTokenURIInput(
        string calldata message,
        uint56 colors,
        bool previewPreferENS
    ) private view returns (
        IEchoCollectionExecutorRenderer.TokenURIInput memory input
    ) {
        (
            bytes3 backgroundColor,
            bytes3 foregroundColor
        ) = colors == 0
            ? _colorsFromConfig(_defaultColors)
            : _unpackColors(colors);

        address core = echoerCore();
        address wallOwner = _wallOwner();
        (uint32 echoCount, ) = EchoerInfoLib.echoCounts(
            IEchoer(core).echoerInfo(wallOwner)
        );

        input = IEchoCollectionExecutorRenderer.TokenURIInput({
            echoerCore: core,
            collection: address(this),
            echoer: wallOwner,

            // A preview has no minted token ID.
            tokenId: 0,

            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            preferENS: previewPreferENS,

            echo: IEchoCollectionExecutorRenderer.EchoData({
                echoId: echoCount,
                echoedAt: uint40(block.timestamp),
                message: message
            })
        });
    }

    function _packTokenId(
        uint32 eID,
        bytes21 dataRef,
        uint40 echoedAt,
        bool customURI
    ) private pure returns (uint256 tokenId) {
        tokenId = (uint256(eID) << 209)
            | (uint256(echoedAt) << 169)
            | (uint256(uint168(dataRef)) << 1)
            | (customURI ? CUSTOM_URI_FLAG : 0);
    }

    function _decodeEchoData(
        bytes calldata data
    ) private pure returns (
        EchoDataKind kind,
        uint56 colors,
        string memory customURI,
        string memory reason
    ) {
        if (data.length == 0) {
            return (EchoDataKind.None, 0, "", "");
        }
        if (data.length < 4) {
            return (EchoDataKind.Unknown, 0, "", "");
        }

        bytes4 tag;
        assembly ("memory-safe") {
            tag := calldataload(data.offset)
        }

        if (tag == ECHO_COLOR_DATA_TAG) {
            if (data.length != 10) {
                return (EchoDataKind.Invalid, 0, "", "Invalid color data");
            }

            bytes3 backgroundColor;
            bytes3 foregroundColor;
            assembly ("memory-safe") {
                backgroundColor := calldataload(add(data.offset, 4))
                foregroundColor := calldataload(add(data.offset, 7))
            }

            colors = _packColors(backgroundColor, foregroundColor);
            return (EchoDataKind.Colors, colors, "", "");
        }

        if (tag == ECHO_CUSTOM_URI_DATA_TAG) {
            if (data.length == 4) {
                return (EchoDataKind.Invalid, 0, "", "Custom URI is empty");
            }
            if (data.length - 4 > MAX_DATA_STORE_STRING_BYTES) {
                return (
                    EchoDataKind.Invalid,
                    0,
                    "",
                    "Custom URI exceeds DataStore maximum length"
                );
            }

            customURI = string(data[4:]);
            if (!_isAllowedCustomURI(customURI)) {
                return (
                    EchoDataKind.Invalid,
                    0,
                    "",
                    "Unsupported custom URI"
                );
            }

            return (EchoDataKind.CustomURI, 0, customURI, "");
        }

        return (EchoDataKind.Unknown, 0, "", "");
    }

    function _usesCustomURI(
        uint256 tokenId
    ) private pure returns (bool) {
        return (tokenId & CUSTOM_URI_FLAG) != 0;
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
                || _startsWith(uri, bytes("btfs://"));
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

    function _packColors(
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) private pure returns (uint56 colors) {
        if (
            backgroundColor == bytes3(0)
                && foregroundColor == bytes3(0)
        ) return 0;

        colors = COLOR_SET_FLAG
            | (uint56(uint24(backgroundColor)) << 24)
            | uint56(uint24(foregroundColor));
    }

    function _unpackColors(
        uint56 colors
    ) private pure returns (
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) {
        backgroundColor = bytes3(uint24(colors >> 24));
        foregroundColor = bytes3(uint24(colors));
    }

    function _colorsFromConfig(
        uint56 colors
    ) private pure returns (
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) {
        if (colors & COLOR_SET_FLAG != 0) {
            return _unpackColors(colors);
        }
        return (
            DEFAULT_BACKGROUND_COLOR,
            DEFAULT_FOREGROUND_COLOR
        );
    }

    function _effectiveColors(
        uint256 tokenId
    ) private view returns (
        bytes3 backgroundColor,
        bytes3 foregroundColor
    ) {
        uint56 colors = _tokenColors[tokenId];
        if (colors & COLOR_SET_FLAG != 0) {
            return _unpackColors(colors);
        }
        return _colorsFromConfig(_defaultColors);
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
        returns (IEchoCollectionExecutorRenderer)
    {
        if (address(_rendererOverride) != address(0)) {
            return _rendererOverride;
        }
        return _defaultRenderer;
    }

    function _activeRenderer(
        uint256 tokenId
    ) private view returns (IEchoCollectionExecutorRenderer) {
        IEchoCollectionExecutorRenderer tokenRenderer_ =
            _tokenRendererOverrides[tokenId];
        if (address(tokenRenderer_) != address(0)) {
            return tokenRenderer_;
        }
        return _activeRenderer();
    }

    /// @dev A broken optional renderer must not make existing metadata
    /// unavailable. The built-in renderer remains the final fallback.
    function _renderTokenURI(
        IEchoCollectionExecutorRenderer renderer_,
        IEchoCollectionExecutorRenderer.TokenURIInput memory input
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

    function _isSupportedRenderer(
        address renderer_
    ) private view returns (bool) {
        if (renderer_.code.length == 0) return false;

        try IERC165(renderer_).supportsInterface(
            type(IEchoCollectionExecutorRenderer).interfaceId
        ) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    /// @notice Checks whether the collection can store the Echo and its data.
    function canEchoFromWall(
        address _owner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    ) external pure returns (
        bool allowed,
        string memory reason
    ) {
        _owner;
        eID;
        if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
            return (false, "Message exceeds DataStore maximum length");
        }

        (
            EchoDataKind kind,
            uint56 colors,
            string memory customURI,
            string memory dataReason
        ) = _decodeEchoData(data);
        colors;

        if (kind == EchoDataKind.Invalid) {
            return (false, dataReason);
        }
        if (
            kind == EchoDataKind.CustomURI
                && !_customDataFits(message, customURI)
        ) {
            return (
                false,
                "Message and custom URI exceed DataStore maximum length"
            );
        }

        return (true, "");
    }

    /// @notice Whether NFT metadata should prefer a usable ENS name.
    bool public preferENSName;

    /// @dev Per-token renderer override. Zero means use collection settings.
    mapping(uint256 tokenId => IEchoCollectionExecutorRenderer renderer_)
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
