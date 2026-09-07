// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";


import {IEchoer} from "./interface/IEchoer.sol";
import {IEchoerWall} from "./interface/IEchoerWall.sol";
import "./interface/IGlobalRegistrar.sol";
import "./interface/IOwnable.sol";
import "./interface/ITornadoCashEchoer.sol";
import {EchoerInfo, EchoerInfoLib} from "./library/EchoerInfoLib.sol";

import {EchoerWall} from "./EchoerWall.sol";



/*
 *                         E C H O E R
 *
 *               A public wall for every onchain address.
 *
 *        Publish on your own Wall, or leave a message on another.
 *        Each message is public and becomes part of the onchain record.
 *
 *        Every wallet or contract address can have a Wall,
 *        even before that address starts using Echoer.
 *        Receiving a message does not mean endorsing it.
 *
 *        Your Wall controls who can send you messages.
 *        Messages may also create NFTs through a connected collection.
 *
 *        Claim a permanent name to make your address easier to find.
 */


/// @title Echoer
/// @notice A global place for permanent names and public on-chain echoes.
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  HOW ECHOER WORKS — QUICK OVERVIEW                              │
/// │                                                                 │
/// │  1. ECHO A MESSAGE                                              │
/// │     Call echo("your message") to record a permanent public Echo │
/// │     on-chain. Echoer emits it as "yourname: your message".      │
/// │                                                                 │
/// │  2. CLAIM A NAME                                                │
/// │     Call claimName("yourname") once. The name is permanently    │
/// │     bound to the address: it cannot be changed, sold or         │
/// │     transferred. Names use a-z, A-Z, 0-9, . and _. Name         │
/// │     ownership is case-insensitive; claimed casing is displayed. │
/// │                                                                 │
/// │  SPECIAL MESSAGE PREFIX                                         │
/// │    # — claims keccak256(message after #) in GlobalRegistrar.    │
/// │        e.g. echo("#my important declaration")                   │
/// │        By default, it also creates an Echo NFT.                 │
/// │                                                                 │
/// │  WALLS                                                          │
/// │     Each address has a deterministic Wall, created only when    │
/// │     needed. It is the account's board; Echoer events remain the │
/// │     permanent public record. A Wall's echo/echoWithData entry   │
/// │     points forward through this Core.                           │
/// └─────────────────────────────────────────────────────────────────┘

/// ┌─────────────────────────────────────────────────────────────────┐
/// │  echoTo - Leave a message on another Wall                       │
/// │                                                                 │
/// │    echoTo(address, message)                                     │
/// │    echoTo(name, message)                                        │
/// │                                                                 │
/// │  RATE LIMITS                                                    │
/// │    Sender limit: each address may call echoTo once per 22 hrs.  │
/// │    Transaction limit: only ONE echoTo per transaction allowed.  │
/// │                                                                 │
/// │  Why the transaction limit?                                     │
/// │    Prevents spam: an attacker cannot create 10 contracts and    │
/// │    call echoTo from each one in a single transaction, thereby   │
/// │    bypassing the 22-hour per-sender cooldown.                   │
/// │                                                                 │
/// │  Consequence: ERC-4337 bundlers cannot batch multiple users'    │
/// │    echoTo calls into one tx. Each user must submit separately.  │
/// │                                                                 │
/// │  A Wall owner may change this default for its own Wall.         │
/// └─────────────────────────────────────────────────────────────────┘
///
/// @dev Names, name claims and Echoer events are deliberately
/// non-transferable and non-economic. There is no owner, no admin
/// function, and no upgrade path.
contract Echoer is IEchoer {
    using Clones for address;
    using EchoerInfoLib for EchoerInfo;

    /// @dev How long a name reservation lasts: 720 hours (30 days).
    uint24 internal constant NAME_RESERVATION_HOURS = 30 days / 1 hours;

    /// @dev For the first ~16 months after deployment, a name must also be free
    /// in the old Global Registrar. After that, only Echoer's own records matter.
    uint24 internal constant REGISTRAR_COMPATIBILITY_HOURS = 16 * 30 days / 1 hours;    
    /// @dev Event text is capped so the public log stays cheap to read.
    /// Longer messages are stored in full by the Wall and its NFTs.
    uint256 private constant MAX_CORE_EVENT_TEXT_BYTES = 96;
    /// @dev Longest message the shared EchoerDataStore can hold.
    uint256 private constant MAX_DATA_STORE_STRING_BYTES = 24_575;

    uint8 private constant NAME_VALID = 0;
    uint8 private constant NAME_EMPTY = 1;
    uint8 private constant NAME_TOO_LONG = 2;
    uint8 private constant NAME_INVALID_CHARACTER = 3;
    uint8 private constant NAME_INVALID_SEPARATOR = 4;

    // Error codes for echoTo validation (CORE_*).
    // Returned by _canEchoAgainstWall and canEchoTo (view) for consistent errors.
    uint8 private constant CORE_OK = 0;
    uint8 private constant CORE_MESSAGE_EMPTY = 1;
    uint8 private constant CORE_HASH_EMPTY = 2;
    uint8 private constant CORE_HASH_CLAIMED = 3;
    uint8 private constant CORE_NAME_TOO_LONG = 4;
    uint8 private constant CORE_ECHO_COUNT_OVERFLOW = 5;
    uint8 private constant CORE_ECHO_OUT_COUNT_OVERFLOW = 6;
    uint8 private constant CORE_SELF_VALUE = 7;
    uint8 private constant CORE_REGISTRAR_FAILED = 8;
    uint8 private constant CORE_COUNTERS_INCONSISTENT = 9;


    /// @inheritdoc IEchoer
    address public immutable override globalRegistrar;

    /// @inheritdoc IEchoer
    uint24 public immutable override registrarUniquenessEndsAtHour;

    address private immutable _wallImplementation;

    /// @notice Who owns or has reserved a name hash, and when.
    /// @dev `expiresAtHour == 0` means the name is claimed forever.
    /// Any other value is a temporary reservation that expires.
    struct NameRecord {
        address account;
        uint24 expiresAtHour;
    }

    /// @dev Values carried between the steps of one echoTo call.
    struct EchoToContext {
        address sender;
        address senderWall;
        address recipientWall;
        bytes32 previousInfo;
    }

    /// @dev One packed slot per account: name length, join week, last echoTo time,
    /// and both Echo counters. See EchoerInfoLib for the bit layout.
    mapping(address account => EchoerInfo info) private _echoerInfo;

    /// @dev keccak256(lowercased name) => who owns or reserved it.
    mapping(bytes32 hashName => NameRecord record) private _nameRecords;

    /// @dev Each account may hold only one live reservation at a time.
    mapping(address account => bytes32 hashName) private _activeReservationHash;

    /// @dev An account that reserves a name for somebody else must wait
    /// until this hour before doing it again.
    mapping(address sponsor => uint24 availableAtHour)
        private _nextSponsoredReservationAtHour;

    /// @dev The original 2016 Echoer contract. The constructor writes one
    /// opening message there so the new Echoer starts from the old one.
    address private constant HISTORIC_ECHOER = 0x756C4628E57F7e7f8a459EC2752968360Cf4D1AA;

    /// @dev Called when Echoer is deployed. Sets up the shared collections
    /// and the Wall template that every account will use.
    /// @param defaultEchoCollection Template for Echo NFT collection.
    /// @param defaultInboxCollection Template for Inbox NFT collection.
    constructor(
        address defaultEchoCollection,
        address defaultInboxCollection
    ) {
        ITornadoCashEchoer(HISTORIC_ECHOER).echo(
            bytes(
                "Echoer begins here. The public wall for every onchain address."
            )
        );


        uint256 currentHour = block.timestamp / 1 hours;
        uint256 compatibilityEnd =
            currentHour + REGISTRAR_COMPATIBILITY_HOURS;
        if (compatibilityEnd > type(uint24).max) {
            revert("Protocol hour overflow");
        }

        globalRegistrar = (0x5564886ca2C518d1964E5FCea4f423b41Db9F561);
        registrarUniquenessEndsAtHour = uint24(compatibilityEnd);

        _wallImplementation = address(
            new EchoerWall(
                defaultEchoCollection,
                defaultInboxCollection
            )
        );

        _claimNameUncheck(address(this), bytes("echoer"), bytes32("Echoer"));
        _claimNameUncheck(_wallImplementation, bytes("wallimplementation"), bytes32("wallImplementation"));
        _claimNameUncheck(defaultEchoCollection, bytes("echocollection"), bytes32("echoCollection"));    
        _claimNameUncheck(defaultInboxCollection, bytes("inboxcollection"), bytes32("inboxCollection"));

    }

    function _claimNameUncheck(address forAddress, bytes memory CanonicalName, bytes32 name) internal {
        _claimCanonicalName(
            forAddress,
            CanonicalName,
            keccak256(CanonicalName),
            name
        );
    }

    // ---------------------------------------------------------------------
    // Names
    // ---------------------------------------------------------------------

    /// @inheritdoc IEchoer
    function reserveName(
        address reservedFor,
        bytes32 hashName
    ) external override {
        if (reservedFor == address(0)) revert("Invalid recipient");
        if (hashName == bytes32(0)) revert("Invalid name hash");

        (, uint8 existingNameLength) = EchoerInfoLib.nameParts(
            _echoerInfo[reservedFor].load()
        );
        if (existingNameLength != 0) revert(_hasPermanentName());

        uint24 currentHour = _currentHour();

        if (msg.sender != reservedFor) {
            bytes32 sponsorInfo = _echoerInfo[msg.sender].load();
            (, uint8 sponsorNameLength) = EchoerInfoLib.nameParts(
                sponsorInfo
            );
            if (sponsorNameLength == 0) {
                revert("Claim name first");
            }

            (uint32 echoCount, uint24 echoOutCount) =
                EchoerInfoLib.echoCounts(sponsorInfo);
            if (uint256(echoCount) <= uint256(echoOutCount)) {
                revert("Make a self-Echo first");
            }
        }

        if (
            currentHour <
            _nextSponsoredReservationAtHour[msg.sender]
        ) {
            revert("reservation cooldown not finished");
        }

        bytes32 activeHash = _activeReservationHash[reservedFor];
        if (activeHash != bytes32(0)) {
            NameRecord memory active = _nameRecords[activeHash];
            if (
                active.account == reservedFor &&
                active.expiresAtHour != 0 &&
                currentHour < active.expiresAtHour
            ) {
                revert("Recipient already has an active reservation");
            }
        }

        NameRecord memory existing = _nameRecords[hashName];
        if (
            existing.account != address(0) &&
            (
                existing.expiresAtHour == 0 ||
                currentHour < existing.expiresAtHour
            )
        ) {
            revert("Name unavailable");
        }

        uint24 expiresAtHour = currentHour + NAME_RESERVATION_HOURS;
        _nameRecords[hashName] = NameRecord({
            account: reservedFor,
            expiresAtHour: expiresAtHour
        });
        _activeReservationHash[reservedFor] = hashName;
        _nextSponsoredReservationAtHour[msg.sender] = expiresAtHour;
        

        emit NameReserved(reservedFor, hashName, expiresAtHour);
    }

    /// @inheritdoc IEchoer
    function claimName(string calldata name) external override {
        (bytes memory canonicalName, uint8 errorCode) = _normalizeName(name);
        _revertIfInvalidName(errorCode);

        (bytes32 hashName, bytes32 displayNameWord) = _claimNameData(
            canonicalName,
            name
        );
        _claimCanonicalName(
            msg.sender,
            canonicalName,
            hashName,
            displayNameWord
        );
    }

    /// @inheritdoc IEchoer
    function claimNameFor(
        address recipient,
        string calldata name,
        bytes calldata signature
    ) external override {
        if (recipient == address(0)) revert("Invalid recipient");

        (bytes memory canonicalName, uint8 errorCode) = _normalizeName(name);
        _revertIfInvalidName(errorCode);

        (bytes32 hashName, bytes32 displayNameWord) = _claimNameData(
            canonicalName,
            name
        );
        if (signature.length == 0) {
            _requireContractOwner(recipient, msg.sender);
        } else {
            _verifyClaimNameSignature(recipient, name, signature);
        }

        _claimCanonicalName(
            recipient,
            canonicalName,
            hashName,
            displayNameWord
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  _verifyClaimNameSignature()
    // ─────────────────────────────────────────────────────────────
    /// @dev Verifies that `recipient` signed the exact claim authorization message.
    ///
    /// Exact signed message:
    /// `I want to claim "{name}" as the permanent name for this wallet in Echoer on Ethereum.`
    ///
    /// This allows another wallet or contract to submit the transaction while proving
    /// that the recipient approved the permanent name claim.
    ///
    /// Reverts if the recovered signer is not `recipient`.
    function _verifyClaimNameSignature(
        address recipient,
        string memory name,
        bytes memory signature
    ) internal pure {
        string memory message = string.concat(
            'I want to claim "',
            name,
            '" as the permanent name for this wallet in Echoer on Ethereum.'
        );

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(bytes(message));

        address signer = ECDSA.recover(digest, signature);

        if (signer != recipient) revert("Invalid signature");
    }

    function _requireContractOwner(
        address recipient,
        address caller
    ) private view {
        if (recipient.code.length == 0) revert("Recipient is not a contract");
        (bool success, bytes memory result) = recipient.staticcall(
            abi.encodeCall(IOwnable.owner, ())
        );
        if (!success || result.length < 32) {
            revert("Contract has no owner function");
        }
        if (abi.decode(result, (address)) != caller) {
            revert("just owner");
        }
    }

    /// @inheritdoc IEchoer
    function isNameAvailable(
        string calldata name
    ) external view override returns (bool) {
        (bytes memory canonicalName, uint8 errorCode) = _normalizeName(name);
        if (errorCode != NAME_VALID) return false;

        return
            _isHashAvailableFor(
                keccak256(canonicalName),
                address(0),
                false,
                _currentHour()
            );
    }

    /// @inheritdoc IEchoer
    function canClaimName(
        address account,
        string calldata name
    )
        external
        view
        override
        returns (bool allowed, string memory reason)
    {
        if (account == address(0)) {
            return (false, "Invalid account");
        }

        (bytes memory canonicalName, uint8 errorCode) = _normalizeName(name);
        if (errorCode != NAME_VALID) {
            return (false, _nameValidationMessage(errorCode));
        }

        (, uint8 existingNameLength) = EchoerInfoLib.nameParts(
            _echoerInfo[account].load()
        );
        if (existingNameLength != 0) {
            return (false, _hasPermanentName());
        }

        return _canClaimNameHash(
            keccak256(canonicalName),
            account,
            _currentHour()
        );
    }

    function _hasPermanentName() internal pure returns (string memory) {
        return "Account already has a permanent name";
    }

    /// @inheritdoc IEchoer
    function addressOf(
        string calldata name
    ) external view override returns (address owner) {
        return _resolveName(name);
    }

    /// @inheritdoc IEchoer
    function addressOfHash(
        bytes32 hashName
    )
        external
        view
        override
        returns (address account, uint24 expiresAtHour)
    {
        NameRecord memory record = _nameRecords[hashName];
        if (record.account == address(0)) return (address(0), 0);

        expiresAtHour = record.expiresAtHour;
        if (expiresAtHour == 0) return (record.account, 0);
        if (_currentHour() < expiresAtHour) {
            return (record.account, expiresAtHour);
        }
        return (address(0), 0);
    }

    /// @inheritdoc IEchoer
    function nameOf(
        address account
    ) public view override returns (string memory name) {
        (bytes18 nameData, uint8 nameLength) = EchoerInfoLib.nameParts(
            _echoerInfo[account].load()
        );
        if (nameLength == 0) return _addressToBase64(account);
        return _unpackName(nameData, nameLength);
    }

    // ---------------------------------------------------------------------
    // Echoer state and Walls
    // ---------------------------------------------------------------------

    /// @inheritdoc IEchoer
    function echoerInfo(
        address account
    ) external view override returns (bytes32 packedInfo) {
        return _echoerInfo[account].load();
    }

    /// @inheritdoc IEchoer
    function wallOf(
        address owner
    ) external view override returns (address wall) {
        return
            _wallImplementation.predictDeterministicAddress(
                _wallSalt(owner),
                address(this)
            );
    }

    function wallOf(
        string calldata name
    ) external view override returns (address wall) {
        address owner = _resolveName(name);
        if (owner == address(0)) return address(0);

        return _wallImplementation.predictDeterministicAddress(
            _wallSalt(owner),
            address(this)
        );
    }

    // ---------------------------------------------------------------------
    // Echoes
    // ---------------------------------------------------------------------

    /// @inheritdoc IEchoer
    function echo(string calldata message) external override {
        _echo(msg.sender, message);
    }

    /// @inheritdoc IEchoer
    function echoWithData(
        string calldata message,
        bytes calldata data
    ) external override {
        _echoWithData(msg.sender, message, data);
    }

    /// @notice Sends a zero-value Echo to a claimed name.
    function echoTo(
        string calldata toName,
        string calldata message
    ) external override {
        address to = _resolveName(toName);
        if (to == address(0)) revert("Unknown recipient");
        _echoTo(msg.sender, to, message, 0);
    }

    /// @notice Sends an Echo to an address and forwards attached value.
    function echoTo(
        address to,
        string calldata message
    ) external payable override {
        if (to == address(0)) revert("Invalid recipient");
        _echoTo(msg.sender, to, message, msg.value);
    }

    /// @inheritdoc IEchoer
    function echoToWithData(
        address to,
        string calldata message,
        bytes calldata data
    ) external payable override {
        if (to == address(0)) revert("Invalid recipient");
        _echoToWithData(msg.sender, to, message, data, msg.value);
    }

    /// @inheritdoc IEchoer
    function onEchoFromWall(
        address sender,
        address wallOwner,
        string calldata message
    ) external override {
        if (
            wallOwner == address(0) ||
            msg.sender != _predictWall(wallOwner)
        ) {
            revert("Only Echoer Wall");
        }

        _echoTo(sender, wallOwner, message, 0);
    }

    /// @inheritdoc IEchoer
    function onEchoWithDataFromWall(
        address sender,
        address wallOwner,
        string calldata message,
        bytes calldata data
    ) external payable override {
        if (
            wallOwner == address(0) ||
            msg.sender != _predictWall(wallOwner)
        ) {
            revert("Only Echoer Wall");
        }

        _echoToWithData(sender, wallOwner, message, data, msg.value);
    }

    /// @inheritdoc IEchoer
    function canEchoTo(
        address from,
        address to,
        uint256 value,
        string calldata message,
        bytes calldata data
    )
        external
        view
        override
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        if (from == address(0)) {
            return (false, false, "Invalid sender");
        }
        if (to == address(0)) {
            return (false, false, "Invalid recipient");
        }
        uint8 coreError = _coreEchoError(from, to, value, message);
        if (coreError != CORE_OK) {
            return (false, false, _coreEchoReason(coreError));
        }

        bytes32 fromInfo = _echoerInfo[from].load();
        address wall = _predictWall(to);

        // A self-target is normalized by _echoTo/_echoToWithData to the
        // ordinary self-Echo path. The Wall can still report whether its Echo
        // collection would be called.
        if (wall.code.length == 0) {
            if (from == to) {
                bool marked = _isMarkedMessage(message);
                if (marked) {
                    if (
                        bytes(message).length >
                        MAX_DATA_STORE_STRING_BYTES
                    ) {
                        return (
                            false,
                            true,
                            "Message exceeds DataStore maximum length"
                        );
                    }
                    return (true, true, "");
                }
                return (true, false, "");
            }

            // An undeployed Wall has the canonical default inbox policy. It
            // is evaluated here because a view cannot deploy the clone.
            return _canEchoAgainstDefaultWall(fromInfo, value, message);
        }

        try IEchoerWall(wall).canEchoFromCore(
            from,
            value,
            message,
            data
        ) returns (
            bool wallAllowed,
            bool wallExecutorWillRun,
            string memory wallReason
        ) {
            return (wallAllowed, wallExecutorWillRun, wallReason);
        } catch (bytes memory revertData) {
            return (
                false,
                false,
                _friendlyRevertMessage(
                    revertData,
                    "Recipient Wall validation failed."
                )
            );
        }
    }

    /// @inheritdoc IEchoer
    function canEchoTo(
        string calldata fromName,
        string calldata toName,
        string calldata message
    )
        external
        view
        override
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        address from = _resolveName(fromName);
        address to = _resolveName(toName);
        if (to == address(0)) {
            return (false, false, "Unknown recipient");
        }

        // Reuse the canonical address-based preview so both overloads stay
        // byte-for-byte consistent. `from` is explicit because this function
        // is also useful as an off-chain eth_call helper.
        return this.canEchoTo(
            from,
            to,
            0,
            message,
            new bytes(0)
        );
    }

    function _coreEchoError(
        address from,
        address to,
        uint256 value,
        string calldata message
    ) private view returns (uint8 errorCode) {
        // `_echoTo` rejects value on a self-Echo before `_prepareEcho`
        // validates the message, so preserve that exact revert precedence.
        if (from == to && value != 0) {
            return CORE_SELF_VALUE;
        }
        if (bytes(message).length == 0) return CORE_MESSAGE_EMPTY;

        bytes32 senderInfo = _echoerInfo[from].load();
        (, uint8 senderNameLength) = EchoerInfoLib.nameParts(senderInfo);
        (uint32 echoCount, uint24 echoOutCount) =
            EchoerInfoLib.echoCounts(senderInfo);

        if (from == to) {
            // _prepareEcho uses a checked subtraction to classify the first
            // self-Echo. Detect a corrupted impossible state before it becomes
            // an opaque Panic(0x11) revert.
            if (uint256(echoOutCount) > uint256(echoCount)) {
                return CORE_COUNTERS_INCONSISTENT;
            }
            if (senderNameLength > 18) return CORE_NAME_TOO_LONG;
            if (echoCount == type(uint32).max) {
                return CORE_ECHO_COUNT_OVERFLOW;
            }
            return _hashMessageError(bytes(message));
        }

        // _prepareEchoTo increments these counters before checking the hash.
        if (echoCount == type(uint32).max) {
            return CORE_ECHO_COUNT_OVERFLOW;
        }
        if (echoOutCount == type(uint24).max) {
            return CORE_ECHO_OUT_COUNT_OVERFLOW;
        }

        uint8 hashError = _hashMessageError(bytes(message));
        if (hashError != CORE_OK) return hashError;

        // `_formatEchoOutMessage` validates the recipient name before the
        // sender-side EchoOut event is emitted.
        (, uint8 recipientNameLength) = EchoerInfoLib.nameParts(
            _echoerInfo[to].load()
        );
        if (recipientNameLength > 18) return CORE_NAME_TOO_LONG;

        // Core formats its own EchoTo event before entering the recipient
        // Wall, so a corrupt sender name wins over every Wall-level error.
        if (senderNameLength > 18) return CORE_NAME_TOO_LONG;
        return CORE_OK;
    }

    function _hashMessageError(
        bytes calldata rawMessage
    ) private view returns (uint8 errorCode) {
        if (rawMessage[0] != bytes1("#")) return CORE_OK;
        if (rawMessage.length == 1) return CORE_HASH_EMPTY;

        bytes32 messageHash = keccak256(rawMessage[1:]);
        try IGlobalRegistrar(globalRegistrar).owner(messageHash) returns (
            address hashOwner
        ) {
            if (hashOwner != address(0)) return CORE_HASH_CLAIMED;
        } catch {
            // The registrar is external and its owner() implementation is
            // outside Core's control. The public preview reports this as a
            // friendly failure below instead of reverting itself.
            return CORE_REGISTRAR_FAILED;
        }

        return CORE_OK;
    }

    function _coreEchoReason(
        uint8 errorCode
    ) private pure returns (string memory) {
        if (errorCode == CORE_MESSAGE_EMPTY) return "Message is empty";
        if (errorCode == CORE_HASH_EMPTY) return "Hash message is empty";
        if (errorCode == CORE_HASH_CLAIMED) {
            return "Message hash already claimed";
        }
        if (errorCode == CORE_NAME_TOO_LONG) {
            return "Invalid stored name length";
        }
        if (errorCode == CORE_ECHO_COUNT_OVERFLOW) {
            return "Echo count limit reached";
        }
        if (errorCode == CORE_ECHO_OUT_COUNT_OVERFLOW) {
            return "Echo-to count limit reached";
        }
        if (errorCode == CORE_SELF_VALUE) {
            return "Self Echo cannot include value";
        }
        if (errorCode == CORE_REGISTRAR_FAILED) {
            return "Global registrar validation failed";
        }
        if (errorCode == CORE_COUNTERS_INCONSISTENT) {
            return "Echoer counters are inconsistent";
        }
        return "Echo is not available";
    }

    function _canEchoAgainstDefaultWall(
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message
    )
        private
        view
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        (, uint8 nameLength) = EchoerInfoLib.nameParts(fromInfo);
        if (nameLength > 18) return (false, false, "Name too long");

        (uint32 echoCount, uint24 echoOutCount) =
            EchoerInfoLib.echoCounts(fromInfo);
        if (echoCount == echoOutCount) {
            return (
                false,
                false,
                "Echo before using echoTo; tell the world something about yourself"
            );
        }
        if (nameLength == 0) {
            return (false, false, "Registered echoer required");
        }

        uint256 availableAtMinute =
            uint256(EchoerInfoLib.lastEchoOutMinute(fromInfo)) + 22 * 60;
        if (block.timestamp / 1 minutes < availableAtMinute) {
            return (false, false, "Echo cooldown not finished");
        }

        if (_endsWithEllipsis(message)) {
            return (false, false, "Message cannot end with ellipsis ...");
        }

        // The default Inbox routes only `#` messages. Check the limits that
        // its mint path and shared DataStore will enforce after lazy deploy.
        if (_isMarkedMessage(message)) {
            if (echoValue > type(uint88).max) {
                return (
                    false,
                    true,
                    "Value exceeds Inbox storage maximum"
                );
            }
            if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
                return (
                    false,
                    true,
                    "Message exceeds DataStore maximum length"
                );
            }
            return (true, true, "");
        }

        return (true, false, "");
    }

    function _isMarkedMessage(
        string calldata message
    ) private pure returns (bool marked) {
        assembly ("memory-safe") {
            marked := and(
                gt(message.length, 0),
                eq(byte(0, calldataload(message.offset)), 0x23)
            )
        }
    }

    function _endsWithEllipsis(
        string calldata message
    ) private pure returns (bool result) {
        assembly ("memory-safe") {
            result := and(
                gt(message.length, 2),
                eq(
                    shr(232, calldataload(add(message.offset, sub(message.length, 3)))),
                    0xe280a6
                )
            )
        }
    }

    function _friendlyRevertMessage(
        bytes memory revertData,
        string memory fallbackMessage
    ) private pure returns (string memory) {
        // Decode the standard Error(string) payload when an external Wall
        // implementation returns one. Unknown/custom payloads receive a clear
        // safe fallback instead of leaking ABI bytes to the user.
        if (revertData.length >= 68) {
            bytes4 selector;
            uint256 stringOffset;
            uint256 stringLength;
            assembly ("memory-safe") {
                selector := mload(add(revertData, 0x20))
                stringOffset := mload(add(revertData, 0x24))
                stringLength := mload(add(revertData, 0x44))
            }
            if (
                selector == 0x08c379a0 &&
                stringOffset == 0x20 &&
                stringLength <= revertData.length - 68
            ) {
                bytes memory message = new bytes(stringLength);
                for (uint256 i; i < stringLength; ) {
                    message[i] = revertData[68 + i];
                    unchecked {
                        ++i;
                    }
                }
                return string(message);
            }
        }
        return fallbackMessage;
    }

    /// @dev Prevents spam: only one echoTo per transaction, regardless of sender.
    ///
    /// Without this check, an attacker could:
    ///   1. Create 10 contract instances in one transaction
    ///   2. Call echoTo from each contract
    ///   3. Bypass the per-sender 22-hour cooldown entirely
    ///   4. Flood a Wall with 10 messages in a single tx
    ///
    /// Trade-off: ERC-4337 bundlers and Safe batches cannot pack multiple
    /// users' echoTo calls into one transaction. Each user must submit
    /// their call in a separate block.
    ///
    /// Stored in transient storage; the EVM clears it when the transaction
    /// ends. No manual reset is needed.
    uint256 transient private _echoToUsedInTransaction;

    /// @dev Enforces: only one echoTo per transaction (anti-spam).
    /// Called at the start of every echoTo entry point.
    function _consumeEchoToForTransaction() internal {
        if (_echoToUsedInTransaction != 0) {
            revert("Only one EchoTo per transaction (anti-spam)");
        }
        _echoToUsedInTransaction = 1;
    }

    // ---------------------------------------------------------------------
    // Internal name logic
    // ---------------------------------------------------------------------

    function _claimCanonicalName(
        address recipient,
        bytes memory canonicalName,
        bytes32 hashName,
        bytes32 displayNameWord
    ) private {
        if (recipient == address(0)) revert("Invalid recipient");

        EchoerInfo storage storedInfo = _echoerInfo[recipient];
        EchoerInfo memory updatedInfo = storedInfo;
        if (updatedInfo.nameLen != 0) revert("Name already permanent");

        uint24 currentHour = _currentHour();
        NameRecord memory existing = _nameRecords[hashName];
        if (existing.account != address(0)) {
            if (existing.expiresAtHour == 0) revert("Name unavailable");
            if (
                currentHour < existing.expiresAtHour &&
                existing.account != recipient
            ) {
                revert("Name reserved for another account");
            }
        }

        if (currentHour < registrarUniquenessEndsAtHour) {
            IGlobalRegistrar registrar = IGlobalRegistrar(globalRegistrar);
            address registrarOwner = registrar.owner(hashName);
            if (
                registrarOwner != address(0) &&
                registrarOwner != recipient &&
                registrar.addr(hashName) != recipient
            ) {
                revert("Name unavailable in registrar");
            }
        }

        updatedInfo.nameData = bytes18(displayNameWord);
        updatedInfo.nameLen = uint8(canonicalName.length);
        if (updatedInfo.createdAtWeek == 0) {
            updatedInfo.createdAtWeek = _currentWeek();
        }

        _echoerInfo[recipient] = updatedInfo;
        _nameRecords[hashName] = NameRecord({
            account: recipient,
            expiresAtHour: 0
        });
        delete _activeReservationHash[recipient];

        emit NameClaimed(recipient, displayNameWord);
    }

    function _isHashAvailableFor(
        bytes32 hashName,
        address account,
        bool mayUseReservation,
        uint24 currentHour
    ) private view returns (bool) {
        NameRecord memory record = _nameRecords[hashName];
        if (record.account != address(0)) {
            if (record.expiresAtHour == 0) return false;
            if (currentHour < record.expiresAtHour) {
                if (!mayUseReservation || record.account != account) {
                    return false;
                }
            }
        }

        if (currentHour < registrarUniquenessEndsAtHour) {
            IGlobalRegistrar registrar = IGlobalRegistrar(globalRegistrar);
            address registrarOwner = registrar.owner(hashName);
            if (registrarOwner != address(0)) {
                if (account == address(0)) return false;
                if (
                    registrarOwner != account &&
                    registrar.addr(hashName) != account
                ) {
                    return false;
                }
            }
        }
        return true;
    }

    function _canClaimNameHash(
        bytes32 hashName,
        address account,
        uint24 currentHour
    )
        private
        view
        returns (bool allowed, string memory reason)
    {
        NameRecord memory record = _nameRecords[hashName];
        if (record.account != address(0)) {
            if (record.expiresAtHour == 0) {
                return (false, "Name already claimed");
            }
            if (
                currentHour < record.expiresAtHour &&
                record.account != account
            ) {
                return (false, "Name reserved for another account");
            }
        }

        if (currentHour >= registrarUniquenessEndsAtHour) {
            return (true, "");
        }

        address registrarOwner;
        try IGlobalRegistrar(globalRegistrar).owner(hashName) returns (
            address owner_
        ) {
            registrarOwner = owner_;
        } catch {
            return (false, "RF");
        }

        if (
            registrarOwner == address(0) ||
            registrarOwner == account
        ) {
            return (true, "");
        }

        try IGlobalRegistrar(globalRegistrar).addr(hashName) returns (
            address registrarAddress
        ) {
            if (registrarAddress == account) return (true, "");
            return (false, "Name unavailable in Global Registrar");
        } catch {
            return (false, "RF");
        }
    }

    function _resolveName(
        string calldata name
    ) private view returns (address owner) {
        uint256 length = bytes(name).length;

        // A 27-byte Base64URL address is the case-sensitive fallback name
        // of an account that has not claimed a permanent Echoer name.
        if (length == 27) {
            (bool validFallback, address decoded) = _tryBase64ToAddress(name);
            return validFallback ? decoded : address(0);
        }

        bytes32 nameHash;
        assembly ("memory-safe") {
            // Copy calldata to scratch memory because KECCAK256 hashes memory.
            let start := mload(0x40)
            calldatacopy(start, name.offset, length)

            // Claimed names are case-insensitive. Fold only ASCII A-Z to a-z.
            // No syntax validation happens here: invalid names simply have no record.
            let cursor := start
            let end := add(start, length)

            for {} lt(cursor, end) { cursor := add(cursor, 1) } {
                let character := byte(0, mload(cursor))

                if and(gt(character, 64), lt(character, 91)) {
                    mstore8(cursor, add(character, 32))
                }
            }

            // Hash the case-folded bytes exactly as claimName stores them.
            nameHash := keccak256(start, length)

            // Preserve Solidity's free-memory-pointer invariant.
            mstore(0x40, and(add(add(start, length), 31), not(31)))
        }

        NameRecord memory record = _nameRecords[nameHash];

        // A non-zero expiry denotes a reservation, never a resolved owner.
        return record.expiresAtHour == 0 ? record.account : address(0);
    }

    function _normalizeName(
        string calldata name
    ) private pure returns (bytes memory canonicalName, uint8 errorCode) {
        bytes calldata input = bytes(name);
        uint256 length = input.length;

        if (length == 0) return (bytes(""), NAME_EMPTY);
        if (length > 18) return (bytes(""), NAME_TOO_LONG);

        canonicalName = new bytes(length);
        bool previousWasSeparator;

        for (uint256 i; i < length; ) {
            uint8 character = uint8(input[i]);
            if (character >= 65 && character <= 90) {
                character += 32;
            }

            bool separator =
                character == 46 || character == 95;
            if (separator) {
                if (i == 0 || previousWasSeparator) {
                    return (bytes(""), NAME_INVALID_SEPARATOR);
                }
                previousWasSeparator = true;
            } else {
                bool letter = character >= 97 && character <= 122;
                bool digit = character >= 48 && character <= 57;
                if (!letter && !digit) {
                    return (bytes(""), NAME_INVALID_CHARACTER);
                }
                previousWasSeparator = false;
            }

            canonicalName[i] = bytes1(character);
            unchecked {
                ++i;
            }
        }

        if (previousWasSeparator) {
            return (bytes(""), NAME_INVALID_SEPARATOR);
        }
        return (canonicalName, NAME_VALID);
    }

    function _revertIfInvalidName(uint8 errorCode) private pure {
        if (errorCode == NAME_VALID) return;
        revert(_nameValidationMessage(errorCode));
    }

    function _nameValidationMessage(
        uint8 errorCode
    ) private pure returns (string memory) {
        if (errorCode == NAME_EMPTY) return "Name is empty";
        if (errorCode == NAME_TOO_LONG) {
            return "Name is longer than 18 bytes";
        }
        if (errorCode == NAME_INVALID_CHARACTER) {
            return "Name contains an invalid character";
        }
        if (errorCode == NAME_INVALID_SEPARATOR) {
            return
                "Name separator cannot be first, last, or repeated consecutively";
        }
        return "Invalid name";
    }

    /// @dev Uses lowercase `canonicalName` only for the ownership hash, while
    /// preserving the caller's validated capitalization in the stored word.
    function _claimNameData(
        bytes memory canonicalName,
        string calldata displayName
    ) private pure returns (bytes32 hashName, bytes32 displayNameWord) {
        hashName = keccak256(canonicalName);
        uint256 length = canonicalName.length;

        assembly ("memory-safe") {
            displayNameWord := calldataload(displayName.offset)
            displayNameWord := and(
                displayNameWord,
                shl(mul(sub(32, length), 8), not(0))
            )
        }
    }

    // ---------------------------------------------------------------------
    // Internal Echo logic
    // ---------------------------------------------------------------------

    /// @dev Internal self-Echo path. The caller must supply the authenticated
    /// effective sender.
    function _echo(
        address sender,
        string calldata message
    ) internal {
        uint32 echoId = _prepareEcho(sender, message);
        IEchoerWall(_getOrCreateWall(sender)).onEchoFromCore(
            sender,
            echoId,
            message
        );
    }

    /// @dev Internal self-Echo-with-data path. The caller must supply the
    /// authenticated effective sender.
    function _echoWithData(
        address sender,
        string calldata message,
        bytes calldata data
    ) internal {
        uint32 echoId = _prepareEcho(sender, message);
        IEchoerWall(_getOrCreateWall(sender)).onEchoWithDataFromCore(
            sender,
            echoId,
            message,
            data
        );
    }

    /// @dev Shared internal EchoTo path. `sender` must come from `msg.sender`
    /// at a user entry point or from an authenticated Wall callback.
    function _echoTo(
        address sender,
        address to,
        string calldata message,
        uint256 value
    ) internal {
        if (sender == to) {
            if (value != 0) revert("Self Echo cannot include value");
            _echo(sender, message);
            return;
        }

        _consumeEchoToForTransaction();
        EchoToContext memory context = _prepareEchoTo(
            sender,
            to,
            message
        );

        IEchoerWall(context.recipientWall).onEchoInFromCore{value: value}(
            to,
            context.sender,
            context.senderWall,
            context.previousInfo,
            message
        );
    }

    /// @dev Data-bearing counterpart of `_echoTo` with the same sender trust
    /// requirement.
    function _echoToWithData(
        address sender,
        address to,
        string calldata message,
        bytes calldata data,
        uint256 value
    ) internal {
        if (sender == to) {
            if (value != 0) revert("Self Echo cannot include value");
            _echoWithData(sender, message, data);
            return;
        }

        _consumeEchoToForTransaction();
        EchoToContext memory context = _prepareEchoTo(
            sender,
            to,
            message
        );

        IEchoerWall(context.recipientWall).onEchoInWithDataFromCore{
            value: value
        }(
            to,
            context.sender,
            context.senderWall,
            context.previousInfo,
            message,
            data
        );
    }

    function _prepareEcho(
        address sender,
        string calldata message
    )
        private
        returns (uint32 echoId)
    {
        _requireMessage(message);

        EchoerInfo storage storedInfo = _echoerInfo[sender];
        EchoerInfo memory updatedInfo = storedInfo;
        echoId = updatedInfo.echoCount;
        
        if (echoId - updatedInfo.echoOutCount == 0) {
            if (updatedInfo.createdAtWeek == 0) {
                updatedInfo.createdAtWeek = _currentWeek();
            }
            
            // The first self-Echo also starts the echoTo cooldown clock.
            if (updatedInfo.lastEchoOutMinute == 0) {
                updatedInfo.lastEchoOutMinute = _currentMinute();
            }

            // tx.origin is used only to decide which event to emit (Direct vs
            // Indirect). It is never used for authorization; a contract can emit
            // DirectEcho if it is called directly by an EOA.
            if (sender == tx.origin) {
                emit FirstDirectEcho(_formatCoreEventText(sender, message));
            } else {
                emit FirstIndirectEcho(_formatCoreEventText(sender, message));
            }
        } else {
            if (sender == tx.origin) {
                emit DirectEcho(_formatCoreEventText(sender, message));
            } else {
                emit IndirectEcho(_formatCoreEventText(sender, message));
            }
        }
        
        updatedInfo.echoCount = echoId + 1;
        _echoerInfo[sender] = updatedInfo;
        _claimHashFromPrefix(message, sender);
    }

    function _prepareEchoTo(
        address sender,
        address to,
        string calldata message
    )
        private
        returns (EchoToContext memory context)
    {
        _requireMessage(message);

        context.sender = sender;
        EchoerInfo storage storedInfo = _echoerInfo[context.sender];

        // The Wall checks the previous send time before this one is saved.
        context.previousInfo = storedInfo.load();
        EchoerInfo memory updatedInfo = storedInfo;
        uint32 echoId = updatedInfo.echoCount;
        updatedInfo.echoCount = echoId + 1;
        updatedInfo.echoOutCount++;
        updatedInfo.lastEchoOutMinute = _currentMinute();
        if (updatedInfo.createdAtWeek == 0) {
            updatedInfo.createdAtWeek = _currentWeek();
        }
        _echoerInfo[context.sender] = updatedInfo;
        _claimHashFromPrefix(message, context.sender);

        context.senderWall = _getOrCreateWall(context.sender);
        context.recipientWall = _getOrCreateWall(to);

        string memory formatted = _formatEchoOutMessage(to, message);
        IEchoerWall(context.senderWall).onEchoOutFromCore(
            uint32(echoId),
            context.recipientWall,
            formatted
        );
        emit EchoTo(
            _formatEchoToCoreEvent(context.sender, formatted)
        );
    }

    error InvalidStoredNameLength();
    // -> toName: message
    function _formatEchoOutMessage(
        address to,
        string calldata message
    ) private view returns (string memory result) {
        (bytes18 nameData, uint8 storedNameLength) = EchoerInfoLib.nameParts(
            _echoerInfo[to].load()
        );

        // Preserve the invariant previously checked by _unpackName().
        if (storedNameLength > 18) revert InvalidStoredNameLength();

        assembly ("memory-safe") {
            /*
             * The Base64URL alphabet is temporarily stored in Solidity's
             * 64-byte scratch space: 0x00...0x3f.
             */
            function base64Character(index) -> character {
                character := byte(
                    and(index, 0x1f),
                    mload(and(index, 0x20))
                )
            }

            function write4(pointer, input) {
                mstore8(pointer, base64Character(shr(18, input)))
                mstore8(add(pointer, 1), base64Character(shr(12, input)))
                mstore8(add(pointer, 2), base64Character(shr(6, input)))
                mstore8(add(pointer, 3), base64Character(input))
            }

            let nameLength := and(storedNameLength, 0xff)
            let renderedNameLength := nameLength

            // An unnamed address has a 27-byte Base64URL fallback.
            if iszero(renderedNameLength) {
                renderedNameLength := 27
            }

            /*
             * 3 bytes: "-> "
             * N bytes: name
             * 2 bytes: ": "
             * M bytes: message
             */
            let messageLength := message.length
            let totalLength := add(
                messageLength,
                add(renderedNameLength, 5)
            )

            result := mload(0x40)
            mstore(result, totalLength)

            let output := add(result, 0x20)

            // Advance the free-memory pointer to the next 32-byte boundary.
            mstore(
                0x40,
                add(
                    output,
                    and(add(totalLength, 0x1f), not(0x1f))
                )
            )

            switch nameLength
            case 0 {
                /*
                 * Fallback header is exactly one word:
                 *
                 * "-> "        3 bytes
                 * Base64URL    27 bytes
                 * ": "         2 bytes
                 * ---------------------
                 *              32 bytes
                 */

                mstore(output, shl(232, 0x2d3e20)) // "-> "

                let nameOutput := add(output, 3)
                let account := and(
                    to,
                    0xffffffffffffffffffffffffffffffffffffffff
                )

                mstore(
                    0x00,
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
                )
                mstore(
                    0x20,
                    "ghijklmnopqrstuvwxyz0123456789-_"
                )

                write4(nameOutput, shr(136, account))
                write4(add(nameOutput, 4), shr(112, account))
                write4(add(nameOutput, 8), shr(88, account))
                write4(add(nameOutput, 12), shr(64, account))
                write4(add(nameOutput, 16), shr(40, account))
                write4(add(nameOutput, 20), shr(16, account))

                let finalInput := shl(8, account)

                mstore8(
                    add(nameOutput, 24),
                    base64Character(shr(18, finalInput))
                )
                mstore8(
                    add(nameOutput, 25),
                    base64Character(shr(12, finalInput))
                )
                mstore8(
                    add(nameOutput, 26),
                    base64Character(shr(6, finalInput))
                )

                mstore8(add(output, 30), 0x3a) // ":"
                mstore8(add(output, 31), 0x20) // " "
            }
            default {
                /*
                 * The complete header fits inside one word because:
                 *
                 * 3 + maximum 18 + 2 = 23 bytes.
                 */

                // Remove any bytes after the declared name length.
                let nameShift := shl(3, sub(32, nameLength))
                let cleanNameData := and(
                    nameData,
                    shl(nameShift, not(0))
                )

                // Start with "-> ".
                let header := shl(232, 0x2d3e20)

                // Put the name immediately after "-> ".
                header := or(
                    header,
                    shr(24, cleanNameData)
                )

                // Put ": " immediately after the name.
                let separatorShift := shl(
                    3,
                    sub(27, nameLength)
                )

                header := or(
                    header,
                    shl(separatorShift, 0x3a20)
                )

                mstore(output, header)
            }

            // Copy the message directly from calldata into the final string.
            calldatacopy(
                add(output, add(renderedNameLength, 5)),
                message.offset,
                messageLength
            )
        }
    }

    /// @dev Returns at most 96 bytes of:
    /// `senderName + " " + formatted`.
    /// Appends `…` (UTF-8 ellipsis) only when truncation occurs, matching
    /// the EchoIn event so both use the same 3-byte marker.
    function _formatEchoToCoreEvent(
        address sender,
        string memory formatted
    ) private view returns (string memory text) {
        (bytes18 senderNameData, uint8 storedNameLength) =
            EchoerInfoLib.nameParts(_echoerInfo[sender].load());

        if (storedNameLength > 18) {
            revert InvalidStoredNameLength();
        }

        assembly ("memory-safe") {
            function base64Character(index) -> character {
                character := byte(
                    and(index, 0x1f),
                    mload(and(index, 0x20))
                )
            }

            function write4(pointer, input) {
                mstore8(pointer, base64Character(shr(18, input)))
                mstore8(add(pointer, 1), base64Character(shr(12, input)))
                mstore8(add(pointer, 2), base64Character(shr(6, input)))
                mstore8(add(pointer, 3), base64Character(input))
            }

            let nameLength := and(storedNameLength, 0xff)
            let renderedNameLength := nameLength

            // Unnamed accounts use the 27-byte Base64URL address.
            if iszero(renderedNameLength) {
                renderedNameLength := 27
            }

            // One space is inserted between senderName and formatted.
            let prefixLength := add(renderedNameLength, 1)
            let formattedLength := mload(formatted)
            let formattedData := add(formatted, 0x20)

            let maximumLength := 96
            let markerLength := 3
            let contentLimit := sub(maximumLength, markerLength) // 93

            let fullLength := add(prefixLength, formattedLength)
            let formattedCopyLength := formattedLength
            let outputLength := fullLength
            let truncated := gt(fullLength, maximumLength)

            if truncated {
                // Reserve three bytes for the `…` marker (3 UTF-8 bytes).
                formattedCopyLength := sub(contentLimit, prefixLength)

                /*
                 * If the cut falls inside a UTF-8 character, move it backward
                 * while the next byte is a continuation byte: 10xxxxxx.
                 */
                for { } and(
                    formattedCopyLength,
                    eq(
                        and(
                            byte(
                                0,
                                mload(
                                    add(
                                        formattedData,
                                        formattedCopyLength
                                    )
                                )
                            ),
                            0xc0
                        ),
                        0x80
                    )
                ) { } {
                    formattedCopyLength := sub(
                        formattedCopyLength,
                        1
                    )
                }

                outputLength := add(
                    add(prefixLength, formattedCopyLength),
                    markerLength
                )
            }

            // Allocate exactly enough rounded memory for the result.
            text := mload(0x40)
            mstore(text, outputLength)

            let output := add(text, 0x20)

            mstore(
                0x40,
                add(
                    output,
                    and(add(outputLength, 0x1f), not(0x1f))
                )
            )

            switch nameLength
            case 0 {
                // Base64URL alphabet in the 64-byte scratch space.
                mstore(
                    0x00,
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
                )
                mstore(
                    0x20,
                    "ghijklmnopqrstuvwxyz0123456789-_"
                )

                let account := and(
                    sender,
                    0xffffffffffffffffffffffffffffffffffffffff
                )

                write4(output, shr(136, account))
                write4(add(output, 4), shr(112, account))
                write4(add(output, 8), shr(88, account))
                write4(add(output, 12), shr(64, account))
                write4(add(output, 16), shr(40, account))
                write4(add(output, 20), shr(16, account))

                let finalInput := shl(8, account)

                mstore8(
                    add(output, 24),
                    base64Character(shr(18, finalInput))
                )
                mstore8(
                    add(output, 25),
                    base64Character(shr(12, finalInput))
                )
                mstore8(
                    add(output, 26),
                    base64Character(shr(6, finalInput))
                )
            }
            default {
                // Keep only the declared bytes of the packed name.
                let nameShift := shl(
                    3,
                    sub(32, nameLength)
                )

                mstore(
                    output,
                    and(
                        senderNameData,
                        shl(nameShift, not(0))
                    )
                )
            }

            // senderName + " "
            mstore8(add(output, renderedNameLength), 0x20)

            // Copy only the required portion of formatted.
            mcopy(
                add(output, prefixLength),
                formattedData,
                formattedCopyLength
            )

            if truncated {
                let markerPosition := add(
                    add(output, prefixLength),
                    formattedCopyLength
                )

                // UTF-8 `…` (0xE2 0x80 0xA6), same 3-byte marker as EchoIn.
                mstore8(markerPosition, 0xe2)
                mstore8(add(markerPosition, 1), 0x80)
                mstore8(add(markerPosition, 2), 0xa6)
            }
        }
    }

    /// @dev Returns at most 96 bytes of:
    /// `senderName + ": " + message`.
    /// Only the message is truncated.
    function _formatCoreEventText(
        address sender,
        string calldata message
    ) private view returns (string memory text) {
        (bytes18 senderNameData, uint8 storedNameLength) =
            EchoerInfoLib.nameParts(_echoerInfo[sender].load());

        if (storedNameLength > 18) {
            revert InvalidStoredNameLength();
        }

        uint256 maximumLength = MAX_CORE_EVENT_TEXT_BYTES;

        assembly ("memory-safe") {
            function base64Character(index) -> character {
                character := byte(
                    and(index, 0x1f),
                    mload(and(index, 0x20))
                )
            }

            function write4(pointer, input) {
                mstore8(pointer, base64Character(shr(18, input)))
                mstore8(add(pointer, 1), base64Character(shr(12, input)))
                mstore8(add(pointer, 2), base64Character(shr(6, input)))
                mstore8(add(pointer, 3), base64Character(input))
            }

            let nameLength := and(storedNameLength, 0xff)
            let renderedNameLength := nameLength

            // Unnamed account: 27-byte Base64URL address.
            if iszero(renderedNameLength) {
                renderedNameLength := 27
            }

            // name + ": "
            let prefixLength := add(renderedNameLength, 2)

            let messageCopyLength := message.length
            let maximumMessageLength := sub(
                maximumLength,
                prefixLength
            )

            if gt(messageCopyLength, maximumMessageLength) {
                messageCopyLength := maximumMessageLength
            }

            let outputLength := add(
                prefixLength,
                messageCopyLength
            )

            // Allocate only the final result.
            text := mload(0x40)
            mstore(text, outputLength)

            let output := add(text, 0x20)

            mstore(
                0x40,
                add(
                    output,
                    and(add(outputLength, 0x1f), not(0x1f))
                )
            )

            switch nameLength
            case 0 {
                mstore(
                    0x00,
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
                )
                mstore(
                    0x20,
                    "ghijklmnopqrstuvwxyz0123456789-_"
                )

                let account := and(
                    sender,
                    0xffffffffffffffffffffffffffffffffffffffff
                )

                write4(output, shr(136, account))
                write4(add(output, 4), shr(112, account))
                write4(add(output, 8), shr(88, account))
                write4(add(output, 12), shr(64, account))
                write4(add(output, 16), shr(40, account))
                write4(add(output, 20), shr(16, account))

                let finalInput := shl(8, account)

                mstore8(
                    add(output, 24),
                    base64Character(shr(18, finalInput))
                )
                mstore8(
                    add(output, 25),
                    base64Character(shr(12, finalInput))
                )
                mstore8(
                    add(output, 26),
                    base64Character(shr(6, finalInput))
                )

                mstore8(add(output, 27), 0x3a) // ":"
                mstore8(add(output, 28), 0x20) // " "
            }
            default {
                // Keep only the declared bytes of the packed name.
                let nameShift := shl(
                    3,
                    sub(32, nameLength)
                )

                let cleanNameData := and(
                    senderNameData,
                    shl(nameShift, not(0))
                )

                // Place ": " immediately after the name.
                let separatorShift := shl(
                    3,
                    sub(30, nameLength)
                )

                let header := or(
                    cleanNameData,
                    shl(separatorShift, 0x3a20)
                )

                mstore(output, header)
            }

            // Copy only the required message bytes directly from calldata.
            calldatacopy(
                add(output, prefixLength),
                message.offset,
                messageCopyLength
            )
        }
    }

    /// @dev If a message starts with `#`, claims the hash of the rest in the
    /// Global Registrar. This creates a timestamped proof of the message.
    /// Does nothing for messages that don't start with `#`.
    function _claimHashFromPrefix(
        string calldata message,
        address recipient
    ) private {
        bytes calldata rawMessage = bytes(message);

        if (rawMessage[0] != bytes1("#")) return;
        if (rawMessage.length == 1) revert("Hash message is empty");

        bytes32 messageHash = keccak256(rawMessage[1:]);
        IGlobalRegistrar registrar = IGlobalRegistrar(globalRegistrar);
        if (registrar.owner(messageHash) != address(0)) {
            revert("Message hash already claimed");
        }

        registrar.reserve(messageHash);
        registrar.transfer(messageHash, recipient);
    }

    function _requireMessage(string calldata message) private pure {
        if (bytes(message).length == 0) revert("Message is empty");
    }

    // ---------------------------------------------------------------------
    // Wall, signature and encoding helpers
    // ---------------------------------------------------------------------

    function _getOrCreateWall(address owner) private returns (address wall) {
        bytes32 salt = _wallSalt(owner);
        wall = _predictWall(owner);

        if (wall.code.length == 0) {
            wall = _wallImplementation.cloneDeterministic(salt);
            IEchoerWall(wall).initialize(owner);
        }
    }

    function _predictWall(address owner) private view returns (address wall) {
        return
            _wallImplementation.predictDeterministicAddress(
                _wallSalt(owner),
                address(this)
            );
    }

    function _wallSalt(address owner) private pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }

   

    /// @dev Accepts only canonical 27-character unpadded Base64URL.
    /// Keep the argument in calldata to avoid copying the string.
    function _tryBase64ToAddress(
        string calldata encoded
    ) internal pure returns (bool success, address account) {
        assembly ("memory-safe") {
            function value(char) -> sextet, bad {
                sextet := byte(0, mload(and(char, 0x7f)))
                bad := or(and(char, 0x80), and(sextet, 0xc0))
            }

            function group(input, index) -> chunk, bad {
                let a, badA := value(byte(index, input))
                let b, badB := value(byte(add(index, 1), input))
                let c, badC := value(byte(add(index, 2), input))
                let d, badD := value(byte(add(index, 3), input))

                bad := or(
                    or(badA, badB),
                    or(badC, badD)
                )

                chunk := or(
                    or(shl(18, a), shl(12, b)),
                    or(shl(6, c), d)
                )
            }

            account := 0
            success := eq(encoded.length, 27)

            if success {
                let freeMemoryPointer := mload(0x40)

                // ASCII -> Base64URL value. 0xff means invalid.
                mstore(
                    0x00,
                    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                )
                mstore(
                    0x20,
                    0xffffffffffffffffffffffffff3effff3435363738393a3b3c3dffffffffffff
                )
                mstore(
                    0x40,
                    0xff000102030405060708090a0b0c0d0e0f10111213141516171819ffffffff3f
                )
                mstore(
                    0x60,
                    0xff1a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30313233ffffffffff
                )

                let input := calldataload(encoded.offset)

                let decoded, err := group(input, 0)
                let chunk, groupErr := group(input, 4)

                decoded := or(shl(24, decoded), chunk)
                err := or(err, groupErr)

                chunk, groupErr := group(input, 8)
                decoded := or(shl(24, decoded), chunk)
                err := or(err, groupErr)

                chunk, groupErr := group(input, 12)
                decoded := or(shl(24, decoded), chunk)
                err := or(err, groupErr)

                chunk, groupErr := group(input, 16)
                decoded := or(shl(24, decoded), chunk)
                err := or(err, groupErr)

                chunk, groupErr := group(input, 20)
                decoded := or(shl(24, decoded), chunk)
                err := or(err, groupErr)

                let a, badA := value(byte(24, input))
                let b, badB := value(byte(25, input))
                let c, badC := value(byte(26, input))

                // and(c, 3) rejects non-canonical trailing bits.
                err := or(
                    err,
                    or(
                        or(badA, badB),
                        or(badC, and(c, 3))
                    )
                )

                let candidate := or(
                    shl(16, decoded),
                    or(
                        shl(10, a),
                        or(shl(4, b), shr(2, c))
                    )
                )

                success := iszero(err)
                account := mul(success, candidate)

                mstore(0x40, freeMemoryPointer)
                mstore(0x60, 0)
            }
        }
    }

    function _unpackName(
        bytes18 data,
        uint8 length
    ) private pure returns (string memory unpackedName) {
        if (length == 0) return "";
        if (length > 18) revert("Name too long");

        assembly ("memory-safe") {
            let nameLength := and(length, 0xff)
            unpackedName := mload(0x40)
            mstore(unpackedName, nameLength)

            let shift := shl(3, sub(32, nameLength))
            let mask := shl(shift, not(0))
            mstore(add(unpackedName, 0x20), and(data, mask))

            mstore(0x40, add(unpackedName, 0x40))
        }
    }

    /// @dev Returns exactly 27 unpadded Base64URL characters. This is kept
    /// byte-for-byte equivalent to EchoerWall's fallback-name encoder.
    function _addressToBase64(
        address account
    ) private pure returns (string memory result) {
        assembly {
            result := mload(0x40)
            mstore(result, 27)

            let output := add(result, 0x20)
            mstore(output, 0)

            mstore(0x1f, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef")
            mstore(0x3f, "ghijklmnopqrstuvwxyz0123456789-_")

            function write4(pointer, input) {
                mstore8(pointer, mload(and(shr(18, input), 0x3f)))
                mstore8(add(pointer, 1), mload(and(shr(12, input), 0x3f)))
                mstore8(add(pointer, 2), mload(and(shr(6, input), 0x3f)))
                mstore8(add(pointer, 3), mload(and(input, 0x3f)))
            }

            write4(output, shr(136, account))
            write4(add(output, 4), shr(112, account))
            write4(add(output, 8), shr(88, account))
            write4(add(output, 12), shr(64, account))
            write4(add(output, 16), shr(40, account))
            write4(add(output, 20), shr(16, account))

            let input := shl(8, account)
            mstore8(add(output, 24), mload(and(shr(18, input), 0x3f)))
            mstore8(add(output, 25), mload(and(shr(12, input), 0x3f)))
            mstore8(add(output, 26), mload(and(shr(6, input), 0x3f)))

            mstore(0x40, add(result, 0x40))
        }
    }

    function _currentHour() private view returns (uint24) {
        return uint24(block.timestamp / 1 hours);
    }

    function _currentWeek() private view returns (uint16) {
        return uint16(block.timestamp / 1 weeks);
    }

    function _currentMinute() private view returns (uint32) {
        return uint32(block.timestamp / 1 minutes);
    }

    /// @notice Returns the account's claimed name or Base64URL fallback packed
    /// into one `bytes32`.
    /// @dev Packed layout:
    /// - Bytes `[0, length)`: name bytes, left-aligned.
    /// - Remaining data bytes: zero.
    /// - Final byte `[31]`: name length.
    /// Claimed names have length 1–18; fallback names have length 27.
    /// Because the final byte contains metadata, do not decode this value with
    /// a standard zero-terminated `bytes32` string decoder.
    function packedNameOf(
        address account
    ) external view override returns (bytes32 packedName) {
        (bytes18 nameData, uint8 storedNameLength) =
            EchoerInfoLib.nameParts(_echoerInfo[account].load());

        if (storedNameLength > 18) {
            revert InvalidStoredNameLength();
        }

        assembly ("memory-safe") {
            function base64Character(index) -> character {
                character := byte(
                    and(index, 0x1f),
                    mload(and(index, 0x20))
                )
            }

            function write4(pointer, input) {
                mstore8(
                    pointer,
                    base64Character(shr(18, input))
                )
                mstore8(
                    add(pointer, 1),
                    base64Character(shr(12, input))
                )
                mstore8(
                    add(pointer, 2),
                    base64Character(shr(6, input))
                )
                mstore8(
                    add(pointer, 3),
                    base64Character(input)
                )
            }

            let nameLength := and(storedNameLength, 0xff)

            switch nameLength
            case 0 {
                // Base64URL alphabet in the 64-byte scratch space.
                mstore(
                    0x00,
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
                )
                mstore(
                    0x20,
                    "ghijklmnopqrstuvwxyz0123456789-_"
                )

                /*
                 * Use one temporary word at the current free-memory pointer.
                 * The pointer does not need to advance because the completed
                 * value is loaded onto the stack before leaving this block.
                 */
                let output := mload(0x40)
                mstore(output, 0)

                let cleanAccount := and(
                    account,
                    0xffffffffffffffffffffffffffffffffffffffff
                )

                write4(output, shr(136, cleanAccount))
                write4(add(output, 4), shr(112, cleanAccount))
                write4(add(output, 8), shr(88, cleanAccount))
                write4(add(output, 12), shr(64, cleanAccount))
                write4(add(output, 16), shr(40, cleanAccount))
                write4(add(output, 20), shr(16, cleanAccount))

                let finalInput := shl(8, cleanAccount)

                mstore8(
                    add(output, 24),
                    base64Character(shr(18, finalInput))
                )
                mstore8(
                    add(output, 25),
                    base64Character(shr(12, finalInput))
                )
                mstore8(
                    add(output, 26),
                    base64Character(shr(6, finalInput))
                )

                // Data occupies bytes 0–26; byte 31 stores length 27.
                packedName := or(mload(output), 27)
            }
            default {
                // Clear every byte after the declared claimed-name length.
                let nameShift := shl(
                    3,
                    sub(32, nameLength)
                )

                let cleanNameData := and(
                    nameData,
                    shl(nameShift, not(0))
                )

                // The final byte is free because claimed names are at most 18 bytes.
                packedName := or(cleanNameData, nameLength)
            }
        }
    }
    
    //Extract the components with:
    //  uint8 nameLength = uint8(uint256(packedName)); 
    //  bytes32 nameData =
    //      packedName & ~bytes32(uint256(0xff));

}


/*
 * +---------------------------------+
 * |                                 |
 * |                                 |
 * |  \           /~~~\           /  |
 * |   '-.     .-'     '-.     .-'   |
 * |      \   /           \   /      |
 * |       \ /             \ /       |
 * |        X               X        |
 * |       / \             / \       |
 * |      /   \           /   \      |
 * |   .-'     '-.     .-'     '-.   |
 * |  /           \~~~/           \  |
 * |                                 |
 * |                                 |
 * +---------------------------------+
 */
