# Echoer

**A public wall for every onchain address.**

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
