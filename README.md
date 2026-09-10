# Echoer

## A public, human-readable communication layer for every Ethereum address

Echoer is an on-chain communication protocol that gives every Ethereum address a permanent public Wall.

Every address has its own deterministic Wall, an immutable space where Echoes can be published. An Echo is a human-readable message attached to an address and stored permanently on-chain.

Unlike traditional messaging systems, Echoer does not require accounts, servers, or external identities. The Ethereum address itself becomes the destination. Both externally owned accounts and smart contracts can participate as senders and receivers.

---

# Public by default

Walls are open by default.

Anyone can send an Echo to another address unless the owner of that Wall defines different rules.

Echoer allows open communication while introducing native anti-spam limitations:

-  Senders establish a basic identity by choosing a short human-readable name. 
-  A sender creates an initial Echo to introduce themselves. 
-  Messaging is rate-limited. 
-  Large-scale message creation in a single transaction is restricted. 

The goal is not to prevent public communication, but to make meaningful communication possible without allowing unlimited abuse.

---

# Beyond Transaction Data

Ethereum transactions can already contain arbitrary data. Some explorers allow users to attach human-readable messages by storing text inside the transaction data field.

However, this communication is only metadata attached to a transaction. It does not create a persistent communication layer for an address.

Sending data directly to a smart contract also depends on the destination contract. The contract must explicitly support receiving and handling that data. Otherwise, the message has no defined meaning or may fail.

Echoer introduces a dedicated communication layer where every address, including smart contracts, has a permanent Wall.

Messages are sent to the identity of an address, not to a specific function or implementation of a contract.

This allows communication with contracts that were not originally designed to receive messages, while keeping communication history separate from the contract’s internal logic.

---

# Immutable Walls, Programmable Execution

The Wall itself is immutable.

The relationship between an address and its Wall, along with the history of Echoes, cannot be changed or rewritten.

However, the behavior triggered by Echoes is programmable.

Each Wall can have execution contracts that react to Echoes. These Executors define what happens when an Echo is created while keeping the Wall itself as a permanent and stable identity layer.

There are two main execution paths:

### EchoExecutor

Handles Echoes created by the Wall owner on their own Wall.

### EchoInExecutor

Handles Echoes sent by other addresses to that Wall.

Executors are programmable and can be replaced or customized according to the needs of each Wall.

The default implementation for incoming Echoes is **Inbox Collection**, a collection contract that can represent received Echoes as programmable digital assets.

This default implementation is only one possible behavior. A Wall owner or application can create a different executor with completely different logic.

A programmable Wall can become much more than a message surface. It can power:

-  vaults, 
-  membership systems, 
-  rewards, 
-  auctions, 
-  collections, 
-  financial logic, 
-  or any custom smart contract behavior. 

---

# Echoes, Collections, and NFTs

Echoes are the fundamental primitive of Echoer.

NFTs are one possible use case built on top of Echoes, not the definition of the protocol.

The default **Inbox Collection** implementation demonstrates how incoming Echoes can become programmable digital assets.

The collection layer is not limited to static metadata. It can be customized and extended for different purposes.

An Echo-based asset can represent:

-  a permanent message, 
-  a collectible, 
-  an access key, 
-  a membership object, 
-  a financial position, 
-  or any other programmable asset defined by its contract. 

The same Echo can have different meanings depending on the Executor logic attached to it.

---

# Human-readable on-chain history

Ethereum addresses are powerful, but difficult for humans to understand.

Echoer adds a human-readable layer around addresses:

-  short names, 
-  introduction Echoes, 
-  public messages, 
-  permanent history. 

An 18-character naming system helps people reference and discover addresses more naturally.

The goal is not to replace Ethereum addresses, but to make their activity understandable for humans.

---

# A protocol, not a social network

Echoer is not a social media platform.

It is a neutral on-chain communication primitive that wallets, explorers, and applications can build upon.

Every Ethereum address already exists.

Echoer gives every address a permanent voice.


## Compilation

Use these settings for the main Echoer contracts:

| Setting | Value |
| --- | --- |
| Solidity compiler | **0.8.36** |
| Optimizer | **Enabled** |
| Optimizer runs | **65** |

Optimizer settings fragment for Solidity Standard JSON:

```json
{
  "settings": {
    "optimizer": {
      "enabled": true,
      "runs": 65
    }
  }
}
```

The contracts import OpenZeppelin Contracts. Supply and pin the compatible dependency version used by your build; the source archive does not include a dependency lockfile.

The contracts use fixed addresses for dependencies deployed on **Ethereum mainnet**. Test using an **Ethereum mainnet fork** so those dependencies are available at their expected addresses.

---

##Immutability and Versioning

Echoer contracts are designed to be immutable.

After the first deployment, the contract code and core behavior cannot be changed. Every user, application, and integration interacts with the same deployed version and the same on-chain rules.

This immutability provides predictable behavior and preserves trust in the protocol.

If a future version introduces new features or different behavior, it will be released as a new deployment with a new contract address. Existing deployments remain unchanged and continue to represent the original version of the protocol.
