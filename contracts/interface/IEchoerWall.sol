// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*
 *                       USING AN ECHOER WALL
 *
 *        Read Echo for the owner's messages.
 *        Read EchoIn for messages received from other Walls.
 *        Read EchoOut for messages sent to other Walls.
 *
 *        Anyone may call echo or echoWithData to send to this Wall.
 *        The current incoming rules decide whether the call succeeds.
 *        Use canEcho first when you are unsure.
 *
 *        Only the Wall owner changes settings or withdraws held ETH.
 *        Functions ending in FromCore are protocol callbacks, not user tools.
 */

/// @dev Echo routing policy. The implementation may pack these flags beside
/// the configured collection address in one storage slot.
struct EchoCondition {
    uint8 flags;
}

/// @dev Incoming-Echo policy. The implementation may pack these values beside
/// the configured collection address in one storage slot.
struct EchoInCondition {
    uint72 minimumValueRequired;
    uint16 minimumCooldownHours;
    uint8 flags;
}

/// @notice Human-readable Wall policy states for apps and explorers.
/// @dev ABI encoding uses the enum's compact numeric value. Apps should show
/// these values as DEFAULT, OPEN, CLOSED and CUSTOM respectively.
enum WallStatus {
    DEFAULT,
    OPEN,
    CLOSED,
    CUSTOM
}

/// @title Echoer Wall interface
/// @notice Public API for an address's message Wall and routing settings.
/// @dev Echoer Core creates each Wall. Echo and Inbox collections are created
/// only when first needed. A collection is an app contract, called an executor,
/// that can react to selected messages. Functions beginning with `on` are Core
/// callbacks and are not normal user actions.
interface IEchoerWall {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice The app used for the owner's Echoes changed.
    event EchoCollectionChange(address indexed echoCollection);

    /// @notice The app used for incoming Echoes changed.
    event InboxCollectionChange(address indexed inboxCollection);

    /// @notice The owner's Echo routing rules changed.
    event EchoConditionChange(EchoCondition echoCondition);

    /// @notice The Wall's incoming rules changed.
    event EchoInConditionChange(EchoInCondition echoInCondition);

    /// @notice One sender was explicitly allowed or rejected by the owner.
    event SenderAccessChange(address indexed sender, bool allowed);

    /// @notice An Echo whose transaction origin differs from the Wall owner.
    /// @dev `origin` is display metadata only and must not be used as authority.
    event Echo(uint32 indexed eID, address indexed origin, string message);

    /// @notice An Echo without separate origin metadata.
    event Echo(uint32 indexed eID, string message);

    /// @notice An incoming Echo recorded on the recipient Wall.
    /// @param fromWall The sender's Wall, enabling direct event navigation.
    /// @param message The display message formatted as `fromName: message`.
    event EchoIn(address indexed fromWall, string message);

    /// @notice Native value was attached to an incoming Echo.
    /// @dev Emitted even when the value is forwarded to the Inbox executor.
    event ValueReceived(
        address indexed from,
        uint256 amount
    );

    /// @notice An outgoing Echo recorded on the sender Wall.
    /// @param eID The sender's Echo counter assigned by Echoer Core.
    /// @param toWall The recipient's Wall, enabling direct event navigation.
    /// @param message The complete display message formatted by Echoer Core as
    /// `-> toName: message`.
    event EchoOut(uint32 indexed eID, address indexed toWall, string message);

    /// @notice ETH held by the Wall was withdrawn.
    event Withdraw(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Identity
    // ---------------------------------------------------------------------

    /// @notice Returns the Echoer Core that created this Wall.
    function echoerCore() external view returns (address);

    /// @notice Returns the address represented by this Wall.
    function owner() external view returns (address);

    /// @notice Initializes a freshly created Wall for `wallOwner`.
    /// @dev Callable only by Echoer Core and only once.
    function initialize(address wallOwner) external;

    /// @return The display name `Wall of <owner name>`.
    function name() external view returns (string memory);

    // ---------------------------------------------------------------------
    // Echo configuration
    // ---------------------------------------------------------------------

    /// @return collection The configured executor. Zero may mean either the
    /// lazy default or disabled routing; `canEcho` reports whether it will run.
    function echoCollection() external view returns (address collection);

    /// @notice Sets or disables the Echo collection independently of routing policy.
    /// @dev Set `collection` to address(0) to disable the Echo executor. A
    /// nonzero address must advertise `IEchoCollectionExecutor` through ERC-165.
    function setEchoCollection(address collection) external;

    /// @notice Restores lazy use of this Wall's deterministic EchoCollection.
    function useDefaultEchoCollection() external;

    /// @notice Sets advanced routing rules for the owner's own Echoes.
    /// @param routeUnmarkedMessages Also route messages without a leading `#`.
    /// @param routeOnlyDataMessages Require application data for routing.
    /// @param suppressOrigin Omit the transaction-origin field from Wall events.
    function setEchoCondition(
        bool routeUnmarkedMessages,
        bool routeOnlyDataMessages,
        bool suppressOrigin
    ) external;

    /// @notice Restores the default Echo routing rules without changing the
    /// selected Echo collection.
    function useDefaultEchoCondition() external;

    /// @notice Returns the current self-Echo routing settings.
    function getEchoCondition()
        external
        view
        returns (
            bool routeUnmarkedMessages,
            bool routeOnlyDataMessages,
            bool suppressOrigin
        );

    // ---------------------------------------------------------------------
    // EchoIn configuration
    // ---------------------------------------------------------------------

    /// @return collection The configured executor. Zero may mean either the
    /// lazy default or disabled routing; `canEcho` reports whether it will run.
    function inboxCollection() external view returns (address collection);

    /// @notice Sets or disables the Inbox collection independently of inbox policy.
    /// @dev Set `collection` to address(0) to disable the Inbox executor. A
    /// nonzero address must advertise `IInboxCollectionExecutor` through ERC-165.
    function setInboxCollection(address collection) external;

    /// @notice Restores lazy use of this Wall's deterministic InboxCollection.
    /// @dev This changes only the collection; inbox policy remains unchanged.
    function useDefaultInboxCollection() external;

    /// @notice Sets advanced incoming and Inbox routing rules for this Wall.
    /// @dev By default only `#` messages are routed. Routing unmarked messages
    /// includes all messages; requiring data filters the selected messages.
    /// @param minimumValueRequired Minimum ETH value in wei.
    /// @param minimumCooldownHours Required hours since the sender's last EchoTo.
    /// @param forwardValueToExecutor Send attached ETH to the Inbox executor.
    /// @param routeUnmarkedMessages Also route messages without a leading `#`.
    /// @param routeOnlyDataMessages Require application data for routing.
    /// @param allowlistMode Reject every sender except addresses admitted with
    /// `setAllow`. When false, `setReject` provides individual blocking.
    /// @param allowUnechoedEchoer Allow senders with no self-Echo.
    /// @param allowUnregisteredEchoer Allow senders with no claimed name.
    function setEchoInCondition(
        uint72 minimumValueRequired,
        uint16 minimumCooldownHours,
        bool forwardValueToExecutor,
        bool routeUnmarkedMessages,
        bool routeOnlyDataMessages,
        bool allowlistMode,
        bool allowUnechoedEchoer,
        bool allowUnregisteredEchoer
    ) external;

    /// @notice Opens this Wall to every sender with no payment or cooldown.
    /// @dev Clears address access rules and preserves the Inbox collection.
    function makeWallOpen() external;

    /// @notice Closes this Wall to every sender.
    /// @dev Clears prior address access rules. The owner may then use
    /// `setAllow` to create a custom allowlist.
    function makeWallClose() external;

    /// @notice Restores the protocol default: the sender needs a claimed name,
    /// a prior self-Echo and 22 hours since their last EchoTo.
    /// @dev Clears address access rules and preserves the Inbox collection.
    function makeWallDefault() external;

    /// @notice Explicitly admits senders in allowlist mode, or removes their
    /// rejection in normal mode.
    function setAllow(address[] calldata senders) external;

    /// @notice Explicitly rejects senders in normal mode, or removes their
    /// admission in allowlist mode.
    function setReject(address[] calldata senders) external;

    /// @notice Changes only the minimum native value required from a sender.
    /// @dev Other effective Wall rules are preserved.
    function requirePayment(uint72 minimumValueRequired) external;

    /// @notice Returns DEFAULT, OPEN, CLOSED or CUSTOM as a compact enum.
    function wallStatus() external view returns (WallStatus status);

    /// @notice Explains the effective sending conditions in plain language.
    /// @dev This is general Wall guidance. Use `canEcho(from, value, message,
    /// data)` for the exact result for one sender and message.
    function wallStatusDescription()
        external
        view
        returns (string memory description);

    /// @notice Returns the current incoming rules and Inbox routing settings.
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
        );

    // ---------------------------------------------------------------------
    // User entry point
    // ---------------------------------------------------------------------

    /// @notice Sends a zero-value, message-only Echo to this Wall's owner.
    /// @dev The Wall forwards the actual caller to Echoer Core. An owner writing
    /// on their own Wall creates a self-Echo; every other caller uses the normal
    /// EchoTo accounting, cooldown and inbox policy. A non-owner message may not
    /// end with `…`, which is reserved for shortened event text.
    function echo(string calldata message) external;

    /// @notice Sends an Echo with application data and optional native value
    /// through Echoer Core. When the caller owns this Wall, Core normalizes
    /// the request to a self-Echo and requires zero native value. Other callers
    /// follow the normal EchoTo rules.
    function echoWithData(
        string calldata message,
        bytes calldata data
    ) external payable;

    /// @notice Checks whether an Echo through this Wall would succeed now.
    /// @dev Validation follows transaction order: Core, Wall, then executor.
    /// @return allowed True when every applicable stage accepts the Echo.
    /// @return executorWillRun True when the configured/default Inbox executor
    /// would be called for this message and data.
    /// @return reason Empty when allowed; otherwise a user-facing explanation.
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
        );

    /// @notice Convenience preview for a zero-value Echo without application
    /// data. `from` is explicit so read-only explorer calls do not depend on
    /// an arbitrary simulated `msg.sender`.
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
        );

    /// @notice Wall-policy and executor stage called by Echoer Core after Core
    /// validation has passed.
    /// @dev Restricted to Echoer Core by the implementation. Keeping this
    /// separate prevents recursion when public `canEcho` asks Core to perform
    /// the complete Core -> Wall -> executor preview.
    function canEchoFromCore(
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
        );

    // ---------------------------------------------------------------------
    // Echoer Core callbacks
    // ---------------------------------------------------------------------

    /// @notice Records an Echo without executor data.
    /// @param wallOwner Trusted owner supplied by Echoer Core, avoiding a Wall
    /// storage read in the executor path.
    function onEchoFromCore(
        address wallOwner,
        uint32 eID,
        string calldata message
    ) external;

    /// @notice Records an Echo with optional application data.
    /// @dev Routing policy decides whether the executor receives the data.
    function onEchoWithDataFromCore(
        address wallOwner,
        uint32 eID,
        string calldata message,
        bytes calldata data
    ) external;

    /// @notice Records an incoming Echo without executor data.
    /// @param wallOwner Trusted recipient owner used for default-inbox
    /// resolution and NFT minting without reading Wall owner storage.
    /// @param from Sender wallet used for the Base64 fallback and executor.
    /// @param fromWall Sender Wall emitted as the navigable counterparty.
    /// @param fromInfo Raw one-slot EchoerInfo snapshot for name and cooldown.
    function onEchoInFromCore(
        address wallOwner,
        address from,
        address fromWall,
        bytes32 fromInfo,
        string calldata message
    ) external payable;

    /// @notice Records an incoming Echo with application data.
    /// @dev Routing policy decides whether the Inbox executor receives it.
    function onEchoInWithDataFromCore(
        address wallOwner,
        address from,
        address fromWall,
        bytes32 fromInfo,
        string calldata message,
        bytes calldata data
    ) external payable;

    /// @notice Emits the sender-side receipt for both data and non-data Echoes.
    /// @dev Core must supply `formattedMessage` as `-> toName: message`.
    /// EchoOut intentionally has no executor, condition or data variant.
    function onEchoOutFromCore(
        uint32 eID,
        address toWall,
        string calldata formattedMessage
    ) external;

    // ---------------------------------------------------------------------
    // Funds
    // ---------------------------------------------------------------------

    /// @notice Sends ETH held by this Wall to `to`. Only the owner may call.
    function withdraw(address to, uint256 amount) external;

    // ---------------------------------------------------------------------
    // Info
    // ---------------------------------------------------------------------
    /// @notice The Wall owner's public note changed.
    event InfoUpdated();

    /// @notice Returns the Wall owner's public note.
    function info() external view returns (string memory);

    /// @notice Changes the public note. Only the owner may call.
    function setInfo(string calldata newInfo) external;

}
