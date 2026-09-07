// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Echoer Core interface
/// @notice Public boundary for a global place of permanent names and public
/// on-chain Echoes.
/// @dev Echoer is the global name space. Its primary public record is the
/// permanent Echo event; deterministic Walls are each account's board. Every
/// Core Echo event text is capped at 96 bytes to keep the public log compact.
///
/// Every address has a display name. Before it claims a name, its display name
/// is the canonical 27-character, case-sensitive, unpadded Base64URL encoding
/// of the raw 20-byte address. A claimed name permanently replaces that
/// fallback and can never be changed or transferred. A temporary reservation
/// gives one address priority to a hash but does not change its display name.
///
/// Claimed names are case-insensitive ASCII strings of 1 to 18 bytes. `A-Z` is
/// normalized to `a-z`. A canonical claimed name must match
/// `[a-z0-9]+([._][a-z0-9]+)*`; therefore `.`, `_` cannot be first,
/// last, repeated or adjacent to each other. For example, `alice_dev` is valid
/// while `.alice`, `alice_`, `alice__art` and `alice-.art` are invalid. Its
/// hash is
/// `keccak256(bytes(canonicalName))`.
///
/// All protocol hour values are `uint24(block.timestamp / 1 hours)`. An expiry
/// or compatibility boundary is active only while `currentHour < boundary`.
interface IEchoer {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A name hash was reserved for an account.
    /// @dev The reservation is claimable only by `reservedFor`. It is active
    /// while `currentHour < expiresAtHour`; at the boundary it is expired. The
    /// plaintext name is intentionally not revealed by this event.
    event NameReserved(
        address indexed reservedFor,
        bytes32 indexed hashName,
        uint24 expiresAtHour
    );

    /// @notice A permanent global name was claimed.
    /// @param name The validated, case-preserved display-name bytes,
    /// left-aligned and zero-padded. This is the actual name, not its hash. Its
    /// length is recoverable from the padding because zero is not valid input.
    event NameClaimed(
        address indexed owner,
        bytes32 name
    );

    /// @notice The first successful self-Echo with a direct sender,
    /// formatted as `name: message`.
    /// @dev Direct means the effective Echo sender equals `tx.origin`. The
    /// effective sender is `msg.sender` at a user-facing Core entry point or
    /// the sender forwarded by an authenticated Wall. This is display metadata
    /// only and must never be used for authorization. "First" means echoCount
    /// equals echoOutCount: the sender's first message about themselves. The
    /// sender may have sent messages to other addresses before this. Event text
    /// is limited to 96 bytes.
    event FirstDirectEcho(string text);

    /// @notice A subsequent successful self-Echo with a direct sender,
    /// formatted as `name: message`.
    /// @dev Direct means the effective Echo sender equals `tx.origin`.
    event DirectEcho(string text);

    /// @notice The first successful self-Echo with an indirect sender,
    /// formatted as `name: message`.
    /// @dev Indirect means the effective Echo sender differs from `tx.origin`.
    /// No `code.length` check is used, so constructor calls are classified
    /// correctly. "First" means echoCount equals echoOutCount: the sender's first
    /// message about themselves. The sender may have sent messages to other
    /// addresses before this.
    event FirstIndirectEcho(string text);

    /// @notice A subsequent successful self-Echo with an indirect sender,
    /// formatted as `name: message`.
    /// @dev Indirect means the effective Echo sender differs from `tx.origin`.
    event IndirectEcho(string text);

    /// @notice An outgoing Echo formatted as `name -> toName: message`.
    /// @dev The names are resolved by `nameOf`. Only as much of `message` as
    /// fits in the 96-byte event-text limit is emitted, so this event remains a
    /// compact global activity board for EOA and contract senders.
    event EchoTo(string text);

    // ---------------------------------------------------------------------
    // Protocol configuration
    // ---------------------------------------------------------------------

    /// @notice The immutable external registrar used for temporary name
    /// uniqueness checks and for hashes claimed by `#` messages.
    function globalRegistrar() external view returns (address);

    /// @notice Exclusive end hour for temporary GlobalRegistrar uniqueness.
    /// @dev Set at deployment to `deploymentHour + 16 * 30 days / 1 hours`.
    /// Name claims require external uniqueness while `currentHour` is less than
    /// this value. Echoer's own global uniqueness remains permanent.
    function registrarUniquenessEndsAtHour()
        external
        view
        returns (uint24);

    // ---------------------------------------------------------------------
    // Names
    // ---------------------------------------------------------------------

    /// @notice Reserves `hashName` for `reservedFor` for a 720-hour protocol
    /// window.
    /// @dev `reservedFor` must be nonzero, have no permanent name, and have no
    /// other active reservation. `hashName` must be nonzero and available; it
    /// should be `keccak256(bytes(canonicalName))`. Anyone may reserve for
    /// themselves. Reserving for another address requires the sponsor to have
    /// a permanent name and at least one self-Echo, and each sponsor may do so
    /// only once per 720 hours. A reservation gives its recipient priority to
    /// that hash for 720 hours, but does not require or block a direct claim of
    /// another available name. GlobalRegistrar uniqueness is checked only when
    /// plaintext is claimed. This unsalted hash does not hide guessable names.
    function reserveName(
        address reservedFor,
        bytes32 hashName
    ) external;

    /// @notice Permanently claims a canonical global name for `msg.sender`.
    /// @dev Each address can claim exactly one name; names cannot be changed or
    /// transferred. Input is case-insensitive and must satisfy the claimed-name
    /// grammar defined above. A prior reservation is optional. If an active
    /// reservation exists for this hash, only its recipient may claim it.
    /// During the compatibility period the name must also be available to this
    /// account in GlobalRegistrar. Ownership is case-insensitive, while the
    /// validated input casing is preserved for display.
    function claimName(string calldata name) external;

    /// @notice Permanently claims `name` for `recipient` using either its
    /// signed authorization or, for an owned deployed contract, its owner.
    /// @dev A nonempty `signature` is an ECDSA personal-sign (EIP-191)
    /// signature over this exact UTF-8 sentence, using `name` exactly as
    /// supplied, including its letter case:
    /// `I want to claim "{name}" as the permanent name for this wallet in Echoer on Ethereum.`
    /// The recovered signer must equal `recipient`. This authorization has no
    /// chain ID, contract address, nonce, or deadline and does not support
    /// ERC-1271; it can therefore be submitted again wherever the same claim
    /// scheme is used until normal permanent-name or availability checks stop
    /// it. When `signature` is empty, `recipient` must be a deployed contract
    /// whose `owner() -> address` function returns `msg.sender`. An EOA cannot
    /// use the empty-signature path. A contract may instead call
    /// `claimName(name)` itself. Reservation and uniqueness rules are the same
    /// as for a direct claim.
    function claimNameFor(
        address recipient,
        string calldata name,
        bytes calldata signature
    ) external;

    /// @notice Returns whether `name` is a valid claimed name with no permanent
    /// claim or active Echoer reservation and passes any active
    /// GlobalRegistrar uniqueness check.
    /// @dev A 27-character Base64URL fallback is already assigned to its decoded
    /// address and is never available as a claimed name.
    function isNameAvailable(
        string calldata name
    ) external view returns (bool);

    /// @notice Checks whether `account` can currently claim `name`, including
    /// an active reservation made specifically for that account.
    /// @dev This checks name validity, the account's permanent-name state,
    /// Echoer reservations and active GlobalRegistrar uniqueness. Authorization
    /// for `claimNameFor` is separate and still requires the proper owner or
    /// signature. `account` is explicit so explorer reads never depend on an
    /// arbitrary simulated `msg.sender`.
    /// @return allowed True when the account can claim the name now.
    /// @return reason Empty when allowed; otherwise a user-facing explanation.
    function canClaimName(
        address account,
        string calldata name
    )
        external
        view
        returns (bool allowed, string memory reason);

    /// @notice Resolves either a claimed name or a default Base64URL name.
    /// @dev Claimed names are resolved case-insensitively. A 27-character
    /// fallback is decoded case-sensitively and must be canonical: encoding the
    /// decoded address again must reproduce the exact input. Active name
    /// reservations do not resolve as ownership.
    /// @return owner The resolved address, or zero when `name` is invalid or an
    /// otherwise-valid claimed name has no permanent owner.
    function addressOf(
        string calldata name
    ) external view returns (address owner);

    /// @notice Resolves the effective record for a canonical name hash.
    /// @dev A permanent claim returns `(owner, 0)`. An active reservation
    /// returns `(reservedFor, expiresAtHour)`. An absent or expired reservation
    /// returns `(address(0), 0)`, even if stale storage awaits lazy cleanup.
    function addressOfHash(
        bytes32 hashName
    ) external view returns (address account, uint24 expiresAtHour);

    /// @notice Returns the current Echoer display name of `account`.
    /// @dev Returns its case-preserved claimed name when one exists; otherwise it
    /// returns the exact 27-character, case-sensitive, unpadded Base64URL
    /// encoding of the raw 20-byte address. Claimed names are at most 18 bytes,
    /// so the two forms cannot collide. Reservations never change this display.
    function nameOf(
        address account
    ) external view returns (string memory name);

    // ---------------------------------------------------------------------
    // Echoer state
    // ---------------------------------------------------------------------

    /// @notice Returns the raw one-slot Echoer state for `account`.
    /// @dev The implementation loads and returns the slot directly through
    /// EchoerInfoLib. Bit offsets from the least-significant bit are fixed:
    /// nameLen [0..7], createdAtWeek [8..23], lastEchoOutMinute [24..55],
    /// echoCount [56..87], echoOutCount [88..111] and nameData [112..255].
    /// Consumers should use EchoerInfoLib to decode it.
    function echoerInfo(
        address account
    )
        external
        view
        returns (bytes32 packedInfo);

    // ---------------------------------------------------------------------
    // Walls
    // ---------------------------------------------------------------------

    /// @notice Returns the owner's deterministic Wall address.
    /// @dev The same address is returned before and after deployment; this view
    /// never deploys the Wall. Echo functions lazily deploy required Walls.
    function wallOf(
        address owner
    ) external view returns (address wall);


    /// @notice Deterministically calculates the Wall for a claimed Echoer name
    /// or a valid 27-byte Base64URL fallback address name.
    /// @dev Returns address(0) when the name cannot resolve to an account.
    ///      This function never deploys the Wall.
    function wallOf(
        string calldata name
    ) external view returns (address wall);

    // ---------------------------------------------------------------------
    // Echoes
    // ---------------------------------------------------------------------

    /// @notice Records an Echo on the caller's Wall.
    /// @dev `message` must be nonempty. A leading `#` claims
    /// `keccak256(bytes(message[1:]))` in GlobalRegistrar for `msg.sender`; the
    /// remainder must also be nonempty. The summary event retains the raw `#`.
    /// This is the only protocol message prefix. Emits exactly one of
    /// `FirstDirectEcho`, `DirectEcho`, `FirstIndirectEcho` or `IndirectEcho`.
    function echo(string calldata message) external;

    /// @notice Records an Echo and forwards application data to the caller's
    /// configured Echo collection. Data is not included in the Wall event.
    /// @dev Uses the same message, prefix and summary-event rules as `echo`.
    function echoWithData(
        string calldata message,
        bytes calldata data
    ) external;

    /// @notice Sends a zero-value Echo to a claimed name or canonical fallback.
    /// @dev This simplified route cannot be used when the recipient's inbox policy
    /// requires value. Use the address overload for value-bearing Echoes. If
    /// `toName` resolves to the caller, the operation is normalized to a
    /// self-Echo and does not consume EchoTo accounting or cooldown.
    function echoTo(
        string calldata toName,
        string calldata message
    ) external;

    /// @notice Sends an Echo directly to an address, optionally with value.
    /// @dev The recipient's inbox policy decides whether the call is accepted and
    /// whether the supplied value is forwarded or retained by the Wall. If
    /// `to == msg.sender`, `msg.value` must be zero and the operation is
    /// normalized to a self-Echo.
    function echoTo(
        address to,
        string calldata message
    ) external payable;

    /// @notice Sends an Echo with application data to `to`.
    /// @dev `to` must be nonzero. Data is forwarded to the recipient's
    /// configured Inbox collection and is not included in Wall events. The
    /// route event derives `toName` through `nameOf(to)`. Message, prefix, value
    /// and route-event rules are otherwise identical to `echoTo`. If
    /// `to == msg.sender`, `msg.value` must be zero and the operation is
    /// normalized to `echoWithData`.
    function echoToWithData(
        address to,
        string calldata message,
        bytes calldata data
    ) external payable;

    /// @notice Checks whether an EchoTo operation would currently succeed.
    /// @return allowed True when Core and the recipient Wall accept the Echo.
    /// @return executorWillRun True when the recipient Inbox executor would be
    /// called by the operation.
    /// @return reason Empty when allowed; otherwise a user-facing explanation.
    function canEchoTo(
        address from,
        address to,
        uint256 value,
        string calldata message,
        bytes calldata data
    )
        external
        view
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        );

    /// @notice Name-based preview for the zero-value, message-only `echoTo`
    /// overload. Returns `Unknown recipient` when the name cannot resolve.
    function canEchoTo(
        string calldata fromName,
        string calldata toName,
        string calldata message
    )
        external
        view
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        );

    // ---------------------------------------------------------------------
    // Wall callback
    // ---------------------------------------------------------------------

    /// @notice Handles a zero-value message submitted through a recipient's
    /// Wall.
    /// @dev Protocol callback: callers must use `echo` on the Wall instead of
    /// calling this function directly. `msg.sender` must be the deterministic
    /// Wall belonging to `wallOwner`; that trusted Wall forwards its actual
    /// caller as `sender`. When `sender == wallOwner`, the request is normalized
    /// to a self-Echo without EchoTo accounting or inbox checks. Otherwise the
    /// normal EchoTo accounting, cooldown and inbox policy checks apply.
    function onEchoFromWall(
        address sender,
        address wallOwner,
        string calldata message
    ) external;

    /// @notice Handles a data-bearing Echo submitted through a recipient Wall.
    function onEchoWithDataFromWall(
        address sender,
        address wallOwner,
        string calldata message,
        bytes calldata data
    ) external payable;


    /// @notice Returns the account name in a packed fixed-size representation.
    /// @dev Layout:
    /// - Bytes 0 through `length - 1`: claimed name or Base64URL fallback.
    /// - Unused middle bytes: zero.
    /// - Byte 31: text length, stored as `uint8`.
    ///
    /// Claimed names have length 1–18.
    /// Address fallbacks have length 27.
    /// This value is not compatible with standard `bytes32` string decoders
    /// because the final byte contains metadata.
    function packedNameOf(
        address account
    ) external view returns (bytes32 packedName);

}
