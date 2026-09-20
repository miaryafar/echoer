// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.36;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "./library/EchoerInfoLib.sol";
import "./library/AddressSeedClones.sol";

import "./interface/IEchoer.sol";
import "./interface/IEchoerWall.sol";
import "./interface/IOwnable.sol";
import "./interface/IInboxCollectionExecutor.sol";
import "./interface/IEchoCollectionExecutor.sol";
import "./interface/ICollectionInitializer.sol";


/*
 *                      E C H O E R   W A L L
 *
 *        This is the public Wall of one onchain address.
 *        It records messages published by that address
 *        and messages accepted from other addresses.
 *
 *        The owner chooses who may send messages:
 *        everyone, selected addresses, or nobody.
 *        The Wall can also require a payment or a waiting period.
 *
 *        Connected collections can turn messages into NFTs.
 *        The owner can replace or disable those connections.
 *        Changing these settings does not erase past messages.
 */



/// @title EchoerWall
/// @notice One address's public message wall. Anyone can post a message here
/// (subject to the owner's rules). All messages are permanent and visible forever.
/// @dev Instantiated once per address. Echoer Core is the trusted operator that
/// routes messages here and verifies the owner. Collection callbacks are
/// synchronous; a callback revert will revert the entire wall operation.
contract EchoerWall is  IEchoerWall{
    using Strings for uint256;

    address public immutable echoerCore;

    /// @dev Clone templates used by all Walls. Not exposed in the ABI by design.
    address internal immutable _echoCollectionImplementation;
    address internal immutable _inboxCollectionImplementation;


    uint256 internal constant MAX_DATA_STORE_STRING_BYTES = 24_575;
    uint16 internal constant DEFAULT_MINIMUM_COOLDOWN_HOURS = 22;


    // Shared collection-routing flags. Used by both Echo and Inbox config
    // to decide which messages reach the collection executor.
    //
    //   ROUTE_ONLY_DATA  ROUTE_UNMARKED   routes when...
    //   ---------------------------------------------------------------
    //          0               0          message starts with '#'
    //          0               1          always
    //          1               0          starts with '#' AND has data
    //          1               1          has data (marker not checked)
    //
    // To route by data alone, without requiring the '#' marker, set both
    // flags — no separate "data only" mode is needed.
    //
    // These flags only matter if a collection exists. Setting the Echo or
    // Inbox collection to address(0) (via setEchoCollection /
    // setInboxCollection) disables routing entirely, regardless of these
    // flags — the message is still recorded as an event, it just never
    // reaches an executor or mints anything.
    uint8 internal constant FLAG_ROUTE_UNMARKED_MESSAGES = 1 << 1;
    uint8 internal constant FLAG_ROUTE_ONLY_DATA_MESSAGES = 1 << 2;

    // Echo-only flags.
    uint8 internal constant FLAG_ECHO_CONDITION_SET = 1 << 0;
    uint8 internal constant FLAG_ECHO_SUPPRESS_ORIGIN = 1 << 6;
    uint8 internal constant FLAG_ECHO_COLLECTION_SET = 1 << 7;

    // Inbox-only flags.
    uint8 internal constant FLAG_FORWARD_VALUE_TO_INBOX = 1 << 0;
    uint8 internal constant INBOX_FLAG_ALLOWLIST_MODE = 1 << 3;
    uint8 internal constant FLAG_ALLOW_UNECHOED_ECHOER = 1 << 4;
    uint8 internal constant FLAG_ALLOW_UNREGISTERED_ECHOER = 1 << 5;
    uint8 internal constant FLAG_ECHO_IN_CONDITION_SET = 1 << 6;
    uint8 internal constant FLAG_INBOX_COLLECTION_SET = 1 << 7;

    uint8 internal constant ECHO_CONDITION_MASK =
        FLAG_ROUTE_UNMARKED_MESSAGES |
        FLAG_ROUTE_ONLY_DATA_MESSAGES |
        FLAG_ECHO_SUPPRESS_ORIGIN;

    uint8 internal constant ECHO_IN_CONDITION_MASK =
        FLAG_FORWARD_VALUE_TO_INBOX |
        FLAG_ROUTE_UNMARKED_MESSAGES |
        FLAG_ROUTE_ONLY_DATA_MESSAGES |
        INBOX_FLAG_ALLOWLIST_MODE |
        FLAG_ALLOW_UNECHOED_ECHOER |
        FLAG_ALLOW_UNREGISTERED_ECHOER;

    // Error codes for incoming echo validation (INCOMING_*).
    // Returned by both _incomingEchoError (mutating) and canEchoTo (view) so
    // they report the same error reason. On success (INCOMING_OK), no string
    // is constructed.
    uint8 private constant INCOMING_OK = 0;
    uint8 private constant INCOMING_MESSAGE_EMPTY = 1;
    uint8 private constant INCOMING_NAME_TOO_LONG = 2;
    uint8 private constant INCOMING_UNECHOED = 3;
    uint8 private constant INCOMING_VALUE = 4;
    uint8 private constant INCOMING_UNREGISTERED = 5;
    uint8 private constant INCOMING_COOLDOWN = 6;
    uint8 private constant INCOMING_ELLIPSIS = 7;
    uint8 private constant INCOMING_SENDER_REJECTED = 8;

    uint8 private constant EXECUTOR_NOT_DEPLOYED = 0;
    uint8 private constant EXECUTOR_REJECTED = 1;
    uint8 private constant EXECUTOR_VALIDATION_FAILED = 2;

 

    /// @dev Exactly one storage slot: 20 + 1 bytes.
    struct EchoConfig {
        address collection;
        uint8 flags;
    }

    /// @dev Exactly one storage slot: 20 + 9 + 2 + 1 bytes.
    struct EchoInConfig {
        address collection;
        uint72 minimumValueRequired;
        uint16 minimumCooldownHours;
        uint8 flags;
    }

    /// @dev One slot. An epoch change invalidates an entire access list without
    /// iterating over addresses; counts make wallStatus() deterministic.
    /// The allow and reject lists always move together, so one epoch covers
    /// both. The effective value is `epoch + 1` — see _epoch().
    struct AccessConfig {
        uint64 epoch;
        uint64 allowedCount;
        uint64 rejectedCount;
    }

    EchoConfig internal _echoConfig;
    EchoInConfig internal _echoInConfig;
    AccessConfig internal _accessConfig;

    /// @dev Low 64 bits store the sender's allow epoch; high 64 bits store the
    /// reject epoch. Stale epochs are ignored.
    mapping(address => uint128) internal _senderAccess;

    constructor(
        address echoCollectionImplementation_,
        address inboxCollectionImplementation_
    ) {
        require(
            ERC165Checker.supportsInterface(
                echoCollectionImplementation_,
                type(IEchoCollectionExecutor).interfaceId
            ),
            "Unsupported Echo collection"
        );
        require(
            ERC165Checker.supportsInterface(
                inboxCollectionImplementation_,
                type(IInboxCollectionExecutor).interfaceId
            ),
            "Unsupported Inbox collection"
        );

        echoerCore = msg.sender;
        _echoCollectionImplementation = echoCollectionImplementation_;
        _inboxCollectionImplementation = inboxCollectionImplementation_;
    }

    function owner() public view returns (address){
        return AddressSeedClones.seedOf(address(this));
    }

    modifier onlyEchoerCore() {
        if (msg.sender != echoerCore) revert("Only Echoer Core");
        _;
    }

    modifier onlyOwner() {
        address currentOwner = owner();
        bool authorized = msg.sender == currentOwner;

        // If the wall owner is a contract, accept its owner as well.
        if (!authorized && currentOwner.code.length != 0) {
            try IOwnable(currentOwner).owner() returns (address contractOwner) {
                authorized = msg.sender == contractOwner;
            } catch {
                authorized = false;
            }
        }

        if (!authorized) revert("Only owner");
        _;
    }

    /// @notice Get a display name for this Wall: "Wall of [owner's name]".
    function name() external view returns (string memory) {
        return string.concat("Wall of ", ownerName());
    }

    /// @notice Get the owner's claimed Echoer name, or their Base64 address if unnamed.
    function ownerName() public view returns (string memory) {
        return IEchoer(echoerCore).nameOf(owner());
    }

    // ---------------------------------------------------------------------
    // Echo configuration
    // ---------------------------------------------------------------------

    /// @return collection The configured executor. Zero may mean either the
    /// lazy default or disabled routing; canEcho reports whether it will run.
    function echoCollection() external view returns (address collection) {
        return _echoConfig.collection;
    }

    /// @notice Sets an Echo collection without changing routing policy.
    /// @dev address(0) disables executor routing. A nonzero address must be a
    /// deployed contract advertising `IEchoCollectionExecutor` through ERC-165.
    function setEchoCollection(address collection) external onlyOwner {
        if (collection != address(0)) {
            require(
                ERC165Checker.supportsInterface(
                    collection,
                    type(IEchoCollectionExecutor).interfaceId
                ),
                "Unsupported Echo collection"
            );
        }

        EchoConfig storage config = _echoConfig;
        config.collection = collection;
        config.flags |= FLAG_ECHO_COLLECTION_SET;

        emit EchoCollectionChange(collection);
    }

    /// @notice Restores lazy use of this Wall's deterministic EchoCollection.
    /// @dev Routing policy is preserved.
    function useDefaultEchoCollection() external onlyOwner {
        EchoConfig storage config = _echoConfig;
        config.collection = address(0);
        config.flags &= ~FLAG_ECHO_COLLECTION_SET;

        emit EchoCollectionChange(address(0));
    }

    function setEchoCondition(
        bool routeUnmarkedMessages,
        bool routeOnlyDataMessages,
        bool suppressOrigin
    ) external onlyOwner {
        EchoConfig storage config = _echoConfig;
        uint8 flags =
            (config.flags & FLAG_ECHO_COLLECTION_SET) |
            FLAG_ECHO_CONDITION_SET;

        if (routeUnmarkedMessages) {
            flags |= FLAG_ROUTE_UNMARKED_MESSAGES;
        }
        if (routeOnlyDataMessages) {
            flags |= FLAG_ROUTE_ONLY_DATA_MESSAGES;
        }
        if (suppressOrigin) flags |= FLAG_ECHO_SUPPRESS_ORIGIN;

        config.flags = flags;
        emit EchoConditionChange(
            EchoCondition({flags: flags & ECHO_CONDITION_MASK})
        );
    }

    /// @notice Restores default Echo routing without changing the collection.
    function useDefaultEchoCondition() external onlyOwner {
        EchoConfig storage config = _echoConfig;
        config.flags &= FLAG_ECHO_COLLECTION_SET;

        emit EchoConditionChange(EchoCondition({flags: 0}));
    }

    function getEchoCondition()
        external
        view
        returns (
            bool routeUnmarkedMessages,
            bool routeOnlyDataMessages,
            bool suppressOrigin
        )
    {
        uint8 flags = _echoConfig.flags;
        return (
            flags & FLAG_ROUTE_UNMARKED_MESSAGES != 0,
            flags & FLAG_ROUTE_ONLY_DATA_MESSAGES != 0,
            flags & FLAG_ECHO_SUPPRESS_ORIGIN != 0
        );
    }

    // ---------------------------------------------------------------------
    // EchoIn configuration
    // ---------------------------------------------------------------------

    /// @return collection The configured executor. Zero may mean either the
    /// lazy default or disabled routing; canEcho reports whether it will run.
    function inboxCollection() external view returns (address collection) {
        return _echoInConfig.collection;
    }

    /// @notice Sets an Inbox collection without changing inbox policy.
    /// @dev address(0) disables executor routing. A nonzero address must be a
    /// deployed contract advertising `IInboxCollectionExecutor` through ERC-165.
    function setInboxCollection(address collection) external onlyOwner {
        if (collection != address(0)) {
            require(
                ERC165Checker.supportsInterface(
                    collection,
                    type(IInboxCollectionExecutor).interfaceId
                ),
                "Unsupported Inbox collection"
            );
        }

        EchoInConfig storage config = _echoInConfig;
        config.collection = collection;
        config.flags |= FLAG_INBOX_COLLECTION_SET;

        emit InboxCollectionChange(collection);
    }

    /// @notice Restores lazy use of this Wall's deterministic InboxCollection.
    /// @dev Inbox policy is preserved.
    function useDefaultInboxCollection() external onlyOwner {
        EchoInConfig storage config = _echoInConfig;
        config.collection = address(0);
        config.flags &= ~FLAG_INBOX_COLLECTION_SET;

        emit InboxCollectionChange(address(0));
    }

    /// @notice Set the rules for who can send messages to this Wall.
    /// Owner-only. Use the makeWall functions for simple presets.
    /// @param minimumValueRequired How much ETH (if any) a sender must include.
    /// @param minimumCooldownHours Rate limit for senders (0 = no limit).
    /// @param forwardValueToExecutor If true, value goes to the message collection.
    ///                               If false, it stays in this Wall.
    /// @param routeUnmarkedMessages If true, all messages are routed to collection.
    ///                              If false, only messages starting with `#`.
    /// @param routeOnlyDataMessages If true, only route messages that include data.
    /// @param allowlistMode If true, reject all senders except addresses added
    /// with setAllow(). If false, setReject() blocks individual addresses.
    /// @param allowUnechoedEchoer If true, senders who've never posted can send.
    /// @param allowUnregisteredEchoer If true, senders without a claimed name can send.
    function setEchoInCondition(
        uint72 minimumValueRequired,
        uint16 minimumCooldownHours,
        bool forwardValueToExecutor,
        bool routeUnmarkedMessages,
        bool routeOnlyDataMessages,
        bool allowlistMode,
        bool allowUnechoedEchoer,
        bool allowUnregisteredEchoer
    ) external onlyOwner {
        bool currentAllowlistMode =
            _effectiveEchoInConfig().flags & INBOX_FLAG_ALLOWLIST_MODE != 0;
        if (allowlistMode != currentAllowlistMode) {
            _resetAccessRules();
        }

        _setEchoInCondition(
            minimumValueRequired,
            minimumCooldownHours,
            forwardValueToExecutor,
            routeUnmarkedMessages,
            routeOnlyDataMessages,
            allowlistMode,
            allowUnechoedEchoer,
            allowUnregisteredEchoer
        );
    }

    /// @notice Opens this Wall to every sender without payment or cooldown.
    function makeWallOpen() external onlyOwner {
        _resetAccessRules();
        _setEchoInCondition(
            0,      // no required native value
            0,      // no sender cooldown
            false,  // attached value remains in the Wall
            false,  // route only messages beginning with `#`
            false,  // data is not required for routing
            false,  // normal access mode with no rejected senders
            true,   // allow senders without a self-Echo
            true    // allow senders without a claimed name
        );
    }

    /// @notice Closes this Wall to every sender.
    /// @dev setAllow() may subsequently admit selected addresses.
    function makeWallClose() external onlyOwner {
        _resetAccessRules();
        _setEchoInCondition(
            0,
            0,
            false,
            false,
            false,
            true,   // an empty allowlist rejects everyone
            true,
            true
        );
    }

    /// @notice Restores the protocol's default incoming policy.
    function makeWallDefault() external onlyOwner {
        _resetAccessRules();

        EchoInConfig storage config = _echoInConfig;
        config.minimumValueRequired = 0;
        config.minimumCooldownHours = 0;
        config.flags &= FLAG_INBOX_COLLECTION_SET;

        emit EchoInConditionChange(
            EchoInCondition({
                minimumValueRequired: 0,
                minimumCooldownHours: DEFAULT_MINIMUM_COOLDOWN_HOURS,
                flags: 0
            })
        );
    }

    /// @notice Allows senders in allowlist mode, or removes their rejection in
    /// normal mode.
    function setAllow(address[] calldata senders) external onlyOwner {
        AccessConfig storage access = _accessConfig;
        uint64 epoch = _epoch();
        bool allowlistMode =
            _effectiveEchoInConfig().flags & INBOX_FLAG_ALLOWLIST_MODE != 0;

        for (uint256 i; i < senders.length; ) {
            address sender = senders[i];
            if (sender == address(0)) revert("Invalid address");

            uint128 senderAccess = _senderAccess[sender];
            if (allowlistMode) {
                if (uint64(senderAccess) != epoch) {
                    _senderAccess[sender] =
                        (senderAccess & ~uint128(type(uint64).max)) |
                        uint128(epoch);
                    ++access.allowedCount;
                    emit SenderAccessChange(sender, true);
                }
            } else if (uint64(senderAccess >> 64) == epoch) {
                _senderAccess[sender] =
                    senderAccess & uint128(type(uint64).max);
                --access.rejectedCount;
                emit SenderAccessChange(sender, true);
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Rejects senders in normal mode, or removes their admission in
    /// allowlist mode.
    function setReject(address[] calldata senders) external onlyOwner {
        AccessConfig storage access = _accessConfig;
        uint64 epoch = _epoch();
        bool allowlistMode =
            _effectiveEchoInConfig().flags & INBOX_FLAG_ALLOWLIST_MODE != 0;

        for (uint256 i; i < senders.length; ) {
            address sender = senders[i];
            if (sender == address(0)) revert("Invalid address");

            uint128 senderAccess = _senderAccess[sender];
            if (allowlistMode) {
                if (uint64(senderAccess) == epoch) {
                    _senderAccess[sender] =
                        senderAccess & ~uint128(type(uint64).max);
                    --access.allowedCount;
                    emit SenderAccessChange(sender, false);
                }
            } else if (uint64(senderAccess >> 64) != epoch) {
                _senderAccess[sender] =
                    (senderAccess & uint128(type(uint64).max)) |
                    (uint128(epoch) << 64);
                ++access.rejectedCount;
                emit SenderAccessChange(sender, false);
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Changes only the required payment and preserves every other
    /// effective incoming rule.
    function requirePayment(uint72 minimumValueRequired) external onlyOwner {
        EchoInConfig memory config = _effectiveEchoInConfig();
        uint8 flags = config.flags;

        _setEchoInCondition(
            minimumValueRequired,
            config.minimumCooldownHours,
            flags & FLAG_FORWARD_VALUE_TO_INBOX != 0,
            flags & FLAG_ROUTE_UNMARKED_MESSAGES != 0,
            flags & FLAG_ROUTE_ONLY_DATA_MESSAGES != 0,
            flags & INBOX_FLAG_ALLOWLIST_MODE != 0,
            flags & FLAG_ALLOW_UNECHOED_ECHOER != 0,
            flags & FLAG_ALLOW_UNREGISTERED_ECHOER != 0
        );
    }

    /// @notice Returns the effective incoming policy as a compact enum.
    function wallStatus() external view returns (WallStatus status) {
        EchoInConfig memory config = _effectiveEchoInConfig();
        AccessConfig memory access = _accessConfig;

        return _wallStatus(config, access);
    }

    /// @notice Explains the effective conditions and how to send in plain
    /// language. canEcho() remains the exact sender-and-message preflight.
    function wallStatusDescription()
        external
        view
        returns (string memory description)
    {
        EchoInConfig memory config = _effectiveEchoInConfig();
        AccessConfig memory access = _accessConfig;
        WallStatus status = _wallStatus(config, access);

        if (status == WallStatus.CLOSED) {
            return
                "Closed: this Wall is not accepting Echoes. Only the Wall owner can allow senders or change the Wall status.";
        }

        if (status == WallStatus.OPEN) {
            return string.concat(
                "Open: anyone can send now. No name, prior self-Echo, payment or cooldown is required.",
                _instruction(false)
            );
        }

        if (status == WallStatus.DEFAULT) {
            return string.concat(
                "Default: claim a name on Echoer Core and publish at least one self-Echo. If you sent an EchoTo recently, wait until 22 hours have passed.",
                _instruction(false)
            );
        }

        uint8 flags = config.flags;
        string memory requirements;

        if (flags & INBOX_FLAG_ALLOWLIST_MODE != 0) {
            requirements =
                "your address must be allowed by the Wall owner";
        } else if (access.rejectedCount != 0) {
            requirements =
                "your address must not be rejected by the Wall owner";
        }

        if (flags & FLAG_ALLOW_UNREGISTERED_ECHOER == 0) {
            requirements = _appendRequirement(
                requirements,
                "claim a name on Echoer Core"
            );
        }

        if (flags & FLAG_ALLOW_UNECHOED_ECHOER == 0) {
            requirements = _appendRequirement(
                requirements,
                "publish at least one self-Echo"
            );
        }

        if (config.minimumCooldownHours != 0) {
            uint256 cooldown = config.minimumCooldownHours;
            requirements = _appendRequirement(
                requirements,
                string.concat(
                    "wait ",
                    cooldown.toString(),
                    cooldown == 1
                        ? " hour after your last EchoTo"
                        : " hours after your last EchoTo"
                )
            );
        }

        if (config.minimumValueRequired != 0) {
            requirements = _appendRequirement(
                requirements,
                string.concat(
                    "send at least ",
                    uint256(config.minimumValueRequired).toString(),
                    " wei with echoWithData(message, data)"
                )
            );
        }

        if (bytes(requirements).length == 0) {
            return string.concat(
                "Custom: anyone can send, but Inbox routing is customized.",
                _instruction(false),
                _instruction(true)
            );
        }

        string memory sendMethod = config.minimumValueRequired == 0
            ? _instruction(false)
            : "";

        return string.concat(
            "Custom: to send, ",
            requirements,
            ".",
            sendMethod,
            _instruction(true)
        );
    }

    function _wallStatus(
        EchoInConfig memory config,
        AccessConfig memory access
    ) private pure returns (WallStatus status) {
        uint8 flags = config.flags & ECHO_IN_CONDITION_MASK;

        if (
            flags & INBOX_FLAG_ALLOWLIST_MODE != 0 &&
            access.allowedCount == 0
        ) return WallStatus.CLOSED;

        if (
            config.minimumValueRequired == 0 &&
            config.minimumCooldownHours == DEFAULT_MINIMUM_COOLDOWN_HOURS &&
            flags == 0 &&
            access.rejectedCount == 0
        ) return WallStatus.DEFAULT;

        uint8 openFlags =
            FLAG_ALLOW_UNECHOED_ECHOER |
            FLAG_ALLOW_UNREGISTERED_ECHOER;
        if (
            config.minimumValueRequired == 0 &&
            config.minimumCooldownHours == 0 &&
            flags == openFlags &&
            access.rejectedCount == 0
        ) return WallStatus.OPEN;

        return WallStatus.CUSTOM;
    }

    function _appendRequirement(
        string memory requirements,
        string memory requirement
    ) private pure returns (string memory) {
        if (bytes(requirements).length == 0) return requirement;
        return string.concat(requirements, "; ", requirement);
    }

    function _instruction(
        bool canEchoCheck
    )
        private
        pure
        returns (string memory)
    {
        return canEchoCheck
            ? " Use canEcho(from, value, message, data) for the exact result."
            : " Call echo(message), or echoWithData(message, data) to include data.";
    }

    function _setEchoInCondition(
        uint72 minimumValueRequired,
        uint16 minimumCooldownHours,
        bool forwardValueToExecutor,
        bool routeUnmarkedMessages,
        bool routeOnlyDataMessages,
        bool allowlistMode,
        bool allowUnechoedEchoer,
        bool allowUnregisteredEchoer
    ) private {
        EchoInConfig storage config = _echoInConfig;
        uint8 flags =
            (config.flags & FLAG_INBOX_COLLECTION_SET) |
            FLAG_ECHO_IN_CONDITION_SET;

        if (forwardValueToExecutor) {
            flags |= FLAG_FORWARD_VALUE_TO_INBOX;
        }
        if (routeUnmarkedMessages) {
            flags |= FLAG_ROUTE_UNMARKED_MESSAGES;
        }
        if (routeOnlyDataMessages) {
            flags |= FLAG_ROUTE_ONLY_DATA_MESSAGES;
        }
        if (allowlistMode) flags |= INBOX_FLAG_ALLOWLIST_MODE;
        if (allowUnechoedEchoer) flags |= FLAG_ALLOW_UNECHOED_ECHOER;
        if (allowUnregisteredEchoer) {
            flags |= FLAG_ALLOW_UNREGISTERED_ECHOER;
        }

        config.minimumValueRequired = minimumValueRequired;
        config.minimumCooldownHours = minimumCooldownHours;
        config.flags = flags;

        emit EchoInConditionChange(
            EchoInCondition({
                minimumValueRequired: minimumValueRequired,
                minimumCooldownHours: minimumCooldownHours,
                flags: flags & ECHO_IN_CONDITION_MASK
            })
        );
    }

    /// @notice Read the current rules for sending messages to this Wall.
    /// Anyone can call this to check what's required before sending.
    /// @return minimumValueRequired ETH required per message (0 = free).
    /// @return minimumCooldownHours Hours to wait between messages (0 = no limit).
    /// @return forwardValueToExecutor Whether value goes to the message collection.
    /// @return routeUnmarkedMessages Whether all messages (not just `#`) are routed.
    /// @return routeOnlyDataMessages Whether only messages with data are routed.
    /// @return allowlistMode Whether only explicitly allowed senders may post.
    /// @return allowUnechoedEchoer Whether senders without prior posts can send.
    /// @return allowUnregisteredEchoer Whether senders without a name can send.
    function getEchoInCondition()
        external
        view
        returns (
            uint72 minimumValueRequired,
            uint16 minimumCooldownHours,
            bool forwardValueToExecutor,
            bool routeUnmarkedMessages,
            bool routeOnlyDataMessages,
            bool allowlistMode,
            bool allowUnechoedEchoer,
            bool allowUnregisteredEchoer
        )
    {
        EchoInConfig memory config = _effectiveEchoInConfig();
        uint8 flags = config.flags;

        return (
            config.minimumValueRequired,
            config.minimumCooldownHours,
            flags & FLAG_FORWARD_VALUE_TO_INBOX != 0,
            flags & FLAG_ROUTE_UNMARKED_MESSAGES != 0,
            flags & FLAG_ROUTE_ONLY_DATA_MESSAGES != 0,
            flags & INBOX_FLAG_ALLOWLIST_MODE != 0,
            flags & FLAG_ALLOW_UNECHOED_ECHOER != 0,
            flags & FLAG_ALLOW_UNREGISTERED_ECHOER != 0
        );
    }

    // ---------------------------------------------------------------------
    // User entry point
    // ---------------------------------------------------------------------

    /// @notice Send a message to this Wall's owner.
    /// @dev Calls Echoer Core to authenticate the Wall and apply rate limits
    /// and permission rules. The sender may be subject to the owner's conditions
    /// (required name, value, etc.). Zero value is assumed.
    function echo(string calldata message) external {
        IEchoer(echoerCore).onEchoFromWall(
            msg.sender,
            owner(),
            message
        );
    }

    /// @inheritdoc IEchoerWall
    function echoWithData(
        string calldata message,
        bytes calldata data
    ) external payable {
        IEchoer(echoerCore).onEchoWithDataFromWall{value: msg.value}(
            msg.sender,
            owner(),
            message,
            data
        );
    }

    /// @inheritdoc IEchoerWall
    function canEcho(
        address from,
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
        )
    {
        // Public Wall previews start at Core so the returned reason always
        // follows the real execution order: Core, Wall, then executor.
        try IEchoer(echoerCore).canEchoTo(
            from,
            owner(),
            value,
            message,
            data
        ) returns (
            bool coreAllowed,
            bool coreExecutorWillRun,
            string memory coreReason
        ) {
            return (coreAllowed, coreExecutorWillRun, coreReason);
        } catch (bytes memory revertData) {
            return (
                false,
                false,
                _friendlyRevertMessage(
                    revertData,
                    "Echoer Core validation failed"
                )
            );
        }
    }

    /// @inheritdoc IEchoerWall
    function canEcho(
        address from,
        string calldata message
    )
        external
        view
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        return this.canEcho(
            from,
            0,
            message,
            new bytes(0)
        );
    }

    /// @inheritdoc IEchoerWall
    function canEchoFromCore(
        address from,
        uint256 value,
        string calldata message,
        bytes calldata data
    )
        external
        view
        onlyEchoerCore
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        bytes32 fromInfo;
        try IEchoer(echoerCore).echoerInfo(from) returns (bytes32 packedInfo) {
            fromInfo = packedInfo;
        } catch {
            return (false, false, "Echoer Core information is unavailable.");
        }

        // Core has already validated the self-Echo. The Wall only needs to
        // resolve the next eID and run its selected Echo executor preflight.
        if (from == owner()) {
            (uint32 eID, ) = EchoerInfoLib.echoCounts(fromInfo);
            return _checkEchoExecutor(
                owner(),
                eID,
                message,
                data
            );
        }

        EchoInConfig memory config = _effectiveEchoInConfig();
        uint8 errorCode = _incomingEchoError(
            from,
            fromInfo,
            value,
            message,
            config
        );

        if (errorCode != INCOMING_OK) {
            return (false, false, _incomingEchoReason(errorCode,fromInfo,value,config));
        }
        

        return _checkInboxExecutor(
            owner(),
            from,
            fromInfo,
            value,
            message,
            data,
            config
        );
    }

    // ---------------------------------------------------------------------
    // Echoer Core callbacks
    // ---------------------------------------------------------------------

    function onEchoFromCore(
        address wallOwner,
        uint32 eID,
        string calldata message
    ) external onlyEchoerCore {
        EchoConfig memory config = _echoConfig;

        if (_shouldRouteToCollection(message, false, config.flags)) {
            address collection = config.collection;
            if (config.flags & FLAG_ECHO_COLLECTION_SET == 0) {
                collection = _getOrCreateDefaultEchoCollection();
            }

            if (collection != address(0)) {
                try IEchoCollectionExecutor(collection).onEchoFromWall(
                    wallOwner,
                    eID,
                    message
                ) {} catch (bytes memory revertData) {
                    _revertExecutorFailure(false, false, revertData);
                }
            }
        }

        _emitEcho(wallOwner, eID, message, config.flags);
    }

    function onEchoWithDataFromCore(
        address wallOwner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    ) external onlyEchoerCore {
        EchoConfig memory config = _echoConfig;

        if (
            _shouldRouteToCollection(
                message,
                data.length != 0,
                config.flags
            )
        ) {
            address collection = config.collection;
            if (config.flags & FLAG_ECHO_COLLECTION_SET == 0) {
                collection = _getOrCreateDefaultEchoCollection();
            }

            if (collection != address(0)) {
                try IEchoCollectionExecutor(collection).onEchoWithDataFromWall(
                    wallOwner,
                    eID,
                    message,
                    data
                ) {} catch (bytes memory revertData) {
                    _revertExecutorFailure(false, false, revertData);
                }
            }
        }

        _emitEcho(wallOwner, eID, message, config.flags);
    }

    function onEchoInFromCore(
        address wallOwner,
        address from,
        address fromWall,
        bytes32 fromInfo,
        string calldata message
    ) external payable onlyEchoerCore {
        EchoInConfig memory config = _effectiveEchoInConfig();
        _validateIncomingEcho(from, fromInfo, msg.value, message, config);

        emit EchoIn(
            fromWall,
            _messageWithName(from, fromInfo, message)
        );
        if (msg.value != 0) {
            emit ValueReceived(from, msg.value);
        }

        if (_shouldRouteToCollection(message, false, config.flags)) {
            address collection = config.collection;
            if (config.flags & FLAG_INBOX_COLLECTION_SET == 0) {
                collection = _getOrCreateDefaultInboxCollection();
            }

            if (collection != address(0)) {
                _routeEchoIn(
                    collection,
                    wallOwner,
                    from,
                    fromInfo,
                    message,
                    config.flags
                );
            }
        }
    }

    function onEchoInWithDataFromCore(
        address wallOwner,
        address from,
        address fromWall,
        bytes32 fromInfo,
        string calldata message,
        bytes calldata data
    ) external payable onlyEchoerCore {
        EchoInConfig memory config = _effectiveEchoInConfig();
        _validateIncomingEcho(from, fromInfo, msg.value, message, config);

        emit EchoIn(
            fromWall,
            _messageWithName(from, fromInfo, message)
        );
        if (msg.value != 0) {
            emit ValueReceived(from, msg.value);
        }

        if (
            _shouldRouteToCollection(
                message,
                data.length != 0,
                config.flags
            )
        ) {
            address collection = config.collection;
            if (config.flags & FLAG_INBOX_COLLECTION_SET == 0) {
                collection = _getOrCreateDefaultInboxCollection();
            }

            if (collection != address(0)) {
                _routeEchoInWithData(
                    collection,
                    wallOwner,
                    from,
                    fromInfo,
                    message,
                    data,
                    config.flags
                );
            }
        }
    }

    /// @notice Emits the sender-side receipt for data and non-data Echoes.
    /// @dev Echoer Core supplies the complete `-> toName: message` string.
    /// EchoOut intentionally has no collection, condition or data variant.
    function onEchoOutFromCore(
        uint32 eID,
        address toWall,
        string calldata formattedMessage
    ) external onlyEchoerCore {
        emit EchoOut(eID, toWall, formattedMessage);
    }

    // ---------------------------------------------------------------------
    // Internal routing and default collections
    // ---------------------------------------------------------------------

    function _getOrCreateDefaultEchoCollection()
        private
        returns (address collection)
    {
        EchoConfig storage config = _echoConfig;

        collection = AddressSeedClones.predictDeterministicAddress(
                            _echoCollectionImplementation, address(this), address(this)
                        );

        // Effects are recorded before initialization. A failure reverts the
        // storage write and clone deployment together.
        config.collection = collection;
        config.flags |= FLAG_ECHO_COLLECTION_SET;

        if (collection.code.length == 0) {
            AddressSeedClones.cloneDeterministic(_echoCollectionImplementation, address(this));
        }

        emit EchoCollectionChange(collection);
    }

    function _getOrCreateDefaultInboxCollection()
        private
        returns (address collection)
    {
        EchoInConfig storage config = _echoInConfig;

        collection = AddressSeedClones.predictDeterministicAddress(
                            _inboxCollectionImplementation, address(this), address(this)
                        );

        config.collection = collection;
        config.flags |= FLAG_INBOX_COLLECTION_SET;

        if (collection.code.length == 0) {
            AddressSeedClones.cloneDeterministic(_inboxCollectionImplementation, address(this));
         
        }

        emit InboxCollectionChange(collection);
    }

    function _effectiveEchoInConfig()
        private
        view
        returns (EchoInConfig memory config)
    {
        config = _echoInConfig;

        if (config.flags & FLAG_ECHO_IN_CONDITION_SET == 0) {
            config.minimumValueRequired = 0;
            config.minimumCooldownHours = DEFAULT_MINIMUM_COOLDOWN_HOURS;
            config.flags &= FLAG_INBOX_COLLECTION_SET;
        }
    }

    /// @dev The effective epoch is the stored one plus one, so a freshly cloned
    /// Wall needs no initializer: its zeroed storage reads as epoch 1, which no
    /// entry in `_senderAccess` can match. An unlisted sender is therefore
    /// admitted in normal mode and refused in allowlist mode, and a stored zero
    /// always means "never listed". Never returns zero, so the values written
    /// into `_senderAccess` stay distinguishable from that untouched state.
    function _epoch() private view returns (uint64) {
        unchecked {
            return _accessConfig.epoch + 1;
        }
    }

    /// @dev Invalidates both lists in constant time. Presets use this so an old
    /// address rule can never survive a new Open, Closed or Default state.
    function _resetAccessRules() private {
        AccessConfig storage access = _accessConfig;

        // Stops one short of the maximum: the effective epoch is stored + 1,
        // and letting the stored value reach the maximum would wrap it to zero.
        if (access.epoch >= type(uint64).max - 1) {
            revert("Access epoch exhausted");
        }

        unchecked {
            ++access.epoch;
        }
        access.allowedCount = 0;
        access.rejectedCount = 0;
    }

    function _isSenderAllowed(
        address sender,
        uint8 flags
    ) private view returns (bool) {
        uint64 epoch = _epoch();
        uint128 senderAccess = _senderAccess[sender];

        if (flags & INBOX_FLAG_ALLOWLIST_MODE != 0) {
            return uint64(senderAccess) == epoch;
        }

        return uint64(senderAccess >> 64) != epoch;
    }

    function _shouldRouteToCollection(
        string calldata message,
        bool hasData,
        uint8 flags
    ) private pure returns (bool) {
        if (
            flags & FLAG_ROUTE_ONLY_DATA_MESSAGES != 0 &&
            !hasData
        ) return false;

        if (flags & FLAG_ROUTE_UNMARKED_MESSAGES != 0) return true;

        // By default, only messages beginning with '#' are routed.
        bool marked;
        assembly ("memory-safe") {
            marked := and(
                gt(message.length, 0),
                eq(byte(0, calldataload(message.offset)), 0x23)
            )
        }
        return marked;
    }

    function _routeEchoIn(
        address collection,
        address wallOwner,
        address from,
        bytes32 fromInfo,
        string calldata message,
        uint8 flags
    ) private {
        uint256 echoValue = msg.value;
        uint256 forwardedValue =
            flags & FLAG_FORWARD_VALUE_TO_INBOX != 0 ? echoValue : 0;

        // `echoValue` always reports what the Wall received. Native value is
        // forwarded independently, allowing the Inbox to record paid value
        // even when the ETH remains withdrawable from the Wall.
        try IInboxCollectionExecutor(collection).onEchoInFromWall{
            value: forwardedValue
        }(wallOwner, from, fromInfo, echoValue, message) {} catch (
            bytes memory revertData
        ) {
            _revertExecutorFailure(true, false, revertData);
        }
    }

    function _routeEchoInWithData(
        address collection,
        address wallOwner,
        address from,
        bytes32 fromInfo,
        string calldata message,
        bytes calldata data,
        uint8 flags
    ) private {
        uint256 echoValue = msg.value;
        uint256 forwardedValue =
            flags & FLAG_FORWARD_VALUE_TO_INBOX != 0 ? echoValue : 0;

        try IInboxCollectionExecutor(collection).onEchoInWithDataFromWall{
            value: forwardedValue
        }(wallOwner, from, fromInfo, echoValue, message, data) {} catch (
            bytes memory revertData
        ) {
            _revertExecutorFailure(true, false, revertData);
        }
    }

    // ---------------------------------------------------------------------
    // Validation and event formatting
    // ---------------------------------------------------------------------

    function _validateIncomingEcho(
        address from,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message,
        EchoInConfig memory config
    ) private view {
        uint8 errorCode = _incomingEchoError(
            from,
            fromInfo,
            echoValue,
            message,
            config
        );

        if (errorCode == INCOMING_OK) return;
        revert(_incomingEchoReason(errorCode,fromInfo,echoValue,config));
    }

    function _incomingEchoError(
        address from,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message,
        EchoInConfig memory config
    ) private view returns (uint8 errorCode) {
        if (bytes(message).length == 0) return INCOMING_MESSAGE_EMPTY;

        uint8 flags = config.flags;
        if (!_isSenderAllowed(from, flags)) {
            return INCOMING_SENDER_REJECTED;
        }

        (, uint8 nameLen) = EchoerInfoLib.nameParts(fromInfo);

        if (nameLen > 18) return INCOMING_NAME_TOO_LONG;

        (uint32 echoCount, uint24 echoOutCount) =
            EchoerInfoLib.echoCounts(fromInfo);
        if (
            (flags & FLAG_ALLOW_UNECHOED_ECHOER) == 0 &&
            echoCount == echoOutCount
        ) {
            return INCOMING_UNECHOED;
        }

        if (echoValue < config.minimumValueRequired) {
            return INCOMING_VALUE;
        }

        if (
            flags & FLAG_ALLOW_UNREGISTERED_ECHOER == 0 &&
            nameLen == 0
        ) {
            return INCOMING_UNREGISTERED;
        }

        uint256 cooldown = config.minimumCooldownHours;
        if (cooldown != 0) {
            uint256 availableAtMinute =
                uint256(EchoerInfoLib.lastEchoOutMinute(fromInfo)) +
                cooldown * 60;

            if (block.timestamp / 1 minutes < availableAtMinute) {
                return INCOMING_COOLDOWN;
            }
        }

        // `_messageWithName` performs this check after admission validation;
        // keeping the same order preserves the transaction's revert reason.
        if (_endsWithEllipsis(message)) return INCOMING_ELLIPSIS;

        return INCOMING_OK;
    }

    function _incomingEchoReason(
        uint8 errorCode,
        bytes32 fromInfo,
        uint256 echoValue,
        EchoInConfig memory config
    ) private view returns (string memory) {
        if (errorCode == INCOMING_MESSAGE_EMPTY) {
            return "Message is empty";
        }

        if (errorCode == INCOMING_NAME_TOO_LONG) {
            return "Name too long";
        }

        if (errorCode == INCOMING_SENDER_REJECTED) {
            return "Sender is not allowed by this Wall";
        }

        if (errorCode == INCOMING_UNECHOED) {
            return
                "Echo() on EchoerCore before using echoTo; tell the world something about yourself";
        }

        if (errorCode == INCOMING_VALUE) {
            uint256 requiredValue = uint256(config.minimumValueRequired);
            uint256 missingValue = requiredValue > echoValue
                ? requiredValue - echoValue
                : 0;

            return string.concat(
                "Insufficient value. Send at least ",
                requiredValue.toString(),
                " wei; ",
                missingValue.toString(),
                " wei more is required."
            );
        }

        if (errorCode == INCOMING_UNREGISTERED) {
            return
                "Registered Echoer required; use claimName() on Echoer Core";
        }

        if (errorCode == INCOMING_COOLDOWN) {
            uint256 availableAtMinute =
                uint256(EchoerInfoLib.lastEchoOutMinute(fromInfo)) +
                uint256(config.minimumCooldownHours) * 60;

            uint256 availableAtTimestamp = availableAtMinute * 1 minutes;

            uint256 remainingSeconds = availableAtTimestamp > block.timestamp
                ? availableAtTimestamp - block.timestamp
                : 0;

            // Round upward, making this the maximum number of hours to wait.
            uint256 remainingHours = (remainingSeconds + 3599) / 60 / 60;

            return string.concat(
                "Echo cooldown not finished. Wait at most ",
                remainingHours.toString(),
                remainingHours == 1 ? " hour." : " hours."
            );
        }

        if (errorCode == INCOMING_ELLIPSIS) {
            return unicode"Message cannot end with … (ellipsis character)";
        }

        return "Echo is not available";
    }

    /// @dev Does the message end with `…` (UTF-8 ellipsis U+2026)?
    /// The three bytes are 0xE2 0x80 0xA6 in UTF-8 encoding.
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

    function _inboxExecutorWillRun(
        string calldata message,
        bool hasData,
        EchoInConfig memory config
    ) private pure returns (bool) {
        if (!_shouldRouteToCollection(message, hasData, config.flags)) {
            return false;
        }

        // A clear collection flag selects the lazy default; a configured
        // executor runs otherwise.
        return
            config.flags & FLAG_INBOX_COLLECTION_SET == 0 ||
            config.collection != address(0);
    }

    function _echoExecutorWillRun(
        string calldata message,
        bool hasData
    ) private view returns (bool) {
        return
            _shouldRouteToCollection(message, hasData, _echoConfig.flags) &&
            (
                _echoConfig.flags & FLAG_ECHO_COLLECTION_SET == 0 ||
                _echoConfig.collection != address(0)
            );
    }

    function _isDefaultEchoCollection(
        address collection
    ) private view returns (bool) {
        return
            collection ==
            AddressSeedClones.predictDeterministicAddress(
                    _echoCollectionImplementation, address(this), address(this)
                );
    }

    function _isDefaultInboxCollection(
        address collection
    ) private view returns (bool) {
        return
            collection ==
            AddressSeedClones.predictDeterministicAddress(
                    _inboxCollectionImplementation, address(this), address(this)
                );
    }

    /// @dev Runs only after Core validation has passed. The return order is
    /// identical to public canEcho(): allowed, executorWillRun, reason.
    function _checkEchoExecutor(
        address wallOwner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    )
        private
        view
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        if (!_echoExecutorWillRun(message, data.length != 0)) {
            return (true, false, "");
        }

        address collection = _echoConfig.collection;

        // Check the shared DataStore limit once for both lazy and deployed
        // forms of the protocol default, without an external call.
        if (
            _echoConfig.flags & FLAG_ECHO_COLLECTION_SET == 0 ||
            _isDefaultEchoCollection(collection)
        ) {
            if (bytes(message).length > MAX_DATA_STORE_STRING_BYTES) {
                return (
                    false,
                    true,
                    "Message exceeds DataStore maximum length"
                );
            }
            return (true, true, "");
        }

        if (collection.code.length == 0) {
            return (
                false,
                true,
                _executorNotice(false, EXECUTOR_NOT_DEPLOYED)
            );
        }

        try IEchoCollectionExecutor(collection).canEchoFromWall(
            wallOwner,
            eID,
            message,
            data
        ) returns (bool executorAllowed, string memory executorReason) {
            if (!executorAllowed) {
                if (bytes(executorReason).length == 0) {
                    executorReason = _executorNotice(
                        false,
                        EXECUTOR_REJECTED
                    );
                }
                return (false, true, executorReason);
            }

            return (true, true, "");
        } catch (bytes memory revertData) {
            return (
                false,
                true,
                _friendlyRevertMessage(
                    revertData,
                    _executorNotice(
                        false,
                        EXECUTOR_VALIDATION_FAILED
                    )
                )
            );
        }
    }

    /// @dev Wall admission has already passed before this function is called.
    /// The executor receives the original Echo value plus the forwarding flag,
    /// which tells it whether the callback will also receive that value as
    /// msg.value.
    function _checkInboxExecutor(
        address wallOwner,
        address from,
        bytes32 fromInfo,
        uint256 echoValue,
        string calldata message,
        bytes calldata data,
        EchoInConfig memory config
    )
        private
        view
        returns (
            bool allowed,
            bool executorWillRun,
            string memory reason
        )
    {
        if (
            !_inboxExecutorWillRun(
                message,
                data.length != 0,
                config
            )
        ) {
            return (true, false, "");
        }

        address collection = config.collection;

        // Validate both lazy and deployed forms of the default Inbox through
        // one shared notification path. Only custom executors are queried.
        if (
            config.flags & FLAG_INBOX_COLLECTION_SET == 0 ||
            _isDefaultInboxCollection(collection)
        ) {
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

        if (collection.code.length == 0) {
            return (
                false,
                true,
                _executorNotice(true, EXECUTOR_NOT_DEPLOYED)
            );
        }

        try IInboxCollectionExecutor(collection).canEchoInFromWall(
            wallOwner,
            from,
            fromInfo,
            echoValue,
            config.flags & FLAG_FORWARD_VALUE_TO_INBOX != 0,
            message,
            data
        ) returns (bool executorAllowed, string memory executorReason) {
            if (!executorAllowed) {
                if (bytes(executorReason).length == 0) {
                    executorReason = _executorNotice(
                        true,
                        EXECUTOR_REJECTED
                    );
                }
                return (false, true, executorReason);
            }

            return (true, true, "");
        } catch (bytes memory revertData) {
            return (
                false,
                true,
                _friendlyRevertMessage(
                    revertData,
                    _executorNotice(
                        true,
                        EXECUTOR_VALIDATION_FAILED
                    )
                )
            );
        }
    }

    /// @dev Reverts with an executor-specific prefix while preserving a
    /// standard Error(string) reason. Empty reasons, panics and custom errors
    /// receive a stable fallback because their raw ABI is not user-readable.
    function _revertExecutorFailure(
        bool inbox,
        bool initialization,
        bytes memory revertData
    ) private pure {
        revert(
            string.concat(
                _executorLabel(inbox),
                initialization ? " initialization: " : ": ",
                _friendlyRevertMessage(
                    revertData,
                    "execution reverted without a readable reason"
                )
            )
        );
    }

    function _executorNotice(
        bool inbox,
        uint8 notice
    ) private pure returns (string memory) {
        string memory label = _executorLabel(inbox);

        if (notice == EXECUTOR_NOT_DEPLOYED) {
            return string.concat("Custom ", label, " is not deployed");
        }
        if (notice == EXECUTOR_REJECTED) {
            return string.concat(label, " rejected the Echo");
        }
        return string.concat(label, " validation failed");
    }

    function _executorLabel(
        bool inbox
    ) private pure returns (string memory) {
        return inbox ? "Inbox executor" : "Echo executor";
    }

    /// @dev Decodes a non-empty standard Error(string) revert reason. Empty
    /// reasons, panics and custom errors receive the supplied fallback.
    function _friendlyRevertMessage(
        bytes memory revertData,
        string memory fallbackMessage
    ) private pure returns (string memory) {
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
                stringLength != 0 &&
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



    function _emitEcho(
        address wallOwner,
        uint32 eID,
        string calldata message,
        uint8 flags
    ) private {
        // tx.origin is display metadata only and is never used for authority.
        address origin = tx.origin;
        if (
            origin == wallOwner ||
            flags & FLAG_ECHO_SUPPRESS_ORIGIN != 0
        ) {
            emit Echo(eID, message);
        } else {
            emit Echo(eID, origin, message);
        }
    }

    /// @dev Formats "name: message" with truncation and the `…` marker.
    /// Truncated messages end with `…` (UTF-8 ellipsis); uncut messages cannot
    /// contain it, so the truncation marker is unambiguous.
    function _messageWithName(
        address from,
        bytes32 fromInfo,
        string calldata message
    ) private pure returns (string memory result) {
        (bytes18 nameData, uint8 nameLen) =
            EchoerInfoLib.nameParts(fromInfo);

        uint256 nameLength = nameLen == 0
            ? 27
            : uint256(nameLen);

        uint256 messageLength;
        assembly ("memory-safe") {
            messageLength := message.length
        }

        uint256 maximumMessageLength;
        unchecked {
            maximumMessageLength = 222 - nameLength;
        }

        uint256 copiedMessageLength = messageLength;
        uint256 markerLength;

        if (messageLength > maximumMessageLength) {
            markerLength = 3;

            unchecked {
                copiedMessageLength = maximumMessageLength - 3;
            }

            assembly ("memory-safe") {
                // Avoid cutting inside a valid UTF-8 character.
                for {
                    let checked := 0
                } and(
                    lt(checked, 3),
                    gt(copiedMessageLength, 0)
                ) {
                    checked := add(checked, 1)
                } {
                    let nextByte := byte(
                        0,
                        calldataload(
                            add(message.offset, copiedMessageLength)
                        )
                    )

                    if iszero(eq(and(nextByte, 0xc0), 0x80)) {
                        break
                    }

                    copiedMessageLength :=
                        sub(copiedMessageLength, 1)
                }
            }
        } else if (messageLength >= 3) {
            bool endsWithMarker;

            assembly ("memory-safe") {
                endsWithMarker := eq(
                    shr(
                        232,
                        calldataload(
                            add(
                                message.offset,
                                sub(messageLength, 3)
                            )
                        )
                    ),
                    0xe280a6 // UTF-8 `…`
                )
            }

            if (endsWithMarker) {
                revert(unicode"Message cannot end with ellipsis …");
            }
        }

        uint256 resultLength;
        unchecked {
            resultLength =
                nameLength +
                2 +
                copiedMessageLength +
                markerLength;
        }

        result = new string(resultLength);

        uint256 output;
        assembly ("memory-safe") {
            output := add(result, 0x20)
        }

        if (nameLen == 0) {
            // Uses scratch memory for the lookup table and restores 0x40.
            assembly {
                function write4(pointer, input) {
                    mstore8(
                        pointer,
                        mload(and(shr(18, input), 0x3f))
                    )
                    mstore8(
                        add(pointer, 1),
                        mload(and(shr(12, input), 0x3f))
                    )
                    mstore8(
                        add(pointer, 2),
                        mload(and(shr(6, input), 0x3f))
                    )
                    mstore8(
                        add(pointer, 3),
                        mload(and(input, 0x3f))
                    )
                }

                let freeMemoryPointer := mload(0x40)

                mstore(
                    0x1f,
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
                )
                mstore(
                    0x3f,
                    "ghijklmnopqrstuvwxyz0123456789-_"
                )

                write4(output, shr(136, from))
                write4(add(output, 4), shr(112, from))
                write4(add(output, 8), shr(88, from))
                write4(add(output, 12), shr(64, from))
                write4(add(output, 16), shr(40, from))
                write4(add(output, 20), shr(16, from))

                let input := shl(8, from)

                mstore8(
                    add(output, 24),
                    mload(and(shr(18, input), 0x3f))
                )
                mstore8(
                    add(output, 25),
                    mload(and(shr(12, input), 0x3f))
                )
                mstore8(
                    add(output, 26),
                    mload(and(shr(6, input), 0x3f))
                )

                mstore(0x40, freeMemoryPointer)
            }
        } else {
            assembly ("memory-safe") {
                mstore(output, nameData)
            }
        }

        assembly ("memory-safe") {
            mstore8(add(output, nameLength), 0x3a) // ':'
            mstore8(
                add(output, add(nameLength, 1)),
                0x20 // ' '
            )

            let messageOutput :=
                add(output, add(nameLength, 2))

            calldatacopy(
                messageOutput,
                message.offset,
                copiedMessageLength
            )

            if markerLength {
                let markerOutput :=
                    add(messageOutput, copiedMessageLength)

                mstore8(markerOutput, 0xe2)
                mstore8(add(markerOutput, 1), 0x80)
                mstore8(add(markerOutput, 2), 0xa6)
            }
        }
    }

    // ---------------------------------------------------------------------
    // Funds
    // ---------------------------------------------------------------------

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert("Invalid address");
        if (address(this).balance < amount) {
            revert("Insufficient balance");
        }

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert("Transfer failed");

        emit Withdraw(to, amount);
    }



    // ---------------------------------------------------------------------
    // INFO
    // ---------------------------------------------------------------------

    /// @notice Current public information displayed by this wall.
    string public info;

    function setInfo(string calldata newInfo) external onlyOwner {
        info = newInfo;
        emit InfoUpdated();
    }
}

/**
                                ┌─────────────────────────────────────┐
                                │     ECHOER: PUBLIC MESSAGE WALL     │
                                └─────────────────────────────────────┘

                              ╔═══════════════════════════════════════╗
                              ║  🔓 This address's wall on-chain  🔓   ║
                              ╚═══════════════════════════════════════╝

     ANYONE CAN SEND                WALL OWNER CONTROLS               EVERYONE CAN READ
     ┌──────────────┐                ┌───────────────┐              ┌──────────────────┐
     │ call echo()  │─────────────→  │  Rules:       │─────────────→│  View events in  │
     │              │   message      │  • Who can?   │   stored     │  block explorer  │
     │ call echo    │─────────────→  │  • Cost?      │   forever    │  (permanent!)    │
     │ WithData()   │   + value      │  • NFT?       │              │                  │
     └──────────────┘   + data       └───────────────┘              └──────────────────┘
                             ↓
                        OWNED BY ADDRESS
                        Can manage rules only


     WORKFLOW: Write Once → Read Forever
     ═════════════════════════════════════════════════════════════════════════════════

           YOU POST          WALL STORES       OWNER SEES         WORLD READS
              ↓                  ↓                  ↓                  ↓
        ┌──────────┐    ┌─────────────┐    ┌────────────┐    ┌──────────────┐
        │ Message  │───→│ In Echoer   │───→│ Events on  │───→│ Public for   │
        │ + value  │    │ (permanent) │    │ their wall │    │ all time     │
        └──────────┘    └─────────────┘    └────────────┘    └──────────────┘


     KEY RULES (Owner Sets These)
     ════════════════════════════════════════════════════════════════════════════════

        Require payment? ─────────→  YES or NO             makeWallOpen() = no limits
        Require a name? ─────────→   YES or NO
        Forward ETH? ────────────→   YES or NO
        Route all or only #? ───→    ALL or # ONLY
        Show events? ─────────────→  YES or NO


     SAFETY
     ════════════════════════════════════════════════════════════════════════════════

     🚫 NEVER POST                              ✅ REMEMBER
     • Private keys, passwords, secrets        • Messages are forever
     • Personal information, email, phone      • Owner may never read it
     • Links from unknown sources             • Verify who sent each message
     • Payment requests                        • Echoer Core handles names
**/
