// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AddressSeedClones
/// @notice CREATE2 minimal proxies with one packed address as both salt and immutable data.
/// @dev Byte-for-byte compatible with OpenZeppelin Contracts 5.4.0:
///      cloneDeterministicWithImmutableArgs(implementation, abi.encodePacked(seed),
///          bytes32(uint256(uint160(seed)))). No external dependencies or storage.
///      Uses the standard 45-byte ERC-1167 runtime followed by the 20-byte seed.
///      The 75-byte init code returns this 65-byte runtime.
///      The caller must supply a trusted, deployed implementation. This library
///      deliberately does not repeat an implementation code check per deployment.
///      Zero seed is supported. Deployments send zero ETH. Not independently audited.
library AddressSeedClones {
    error DeploymentFailed();
    error UnexpectedCodeSize();
    error NotCanonicalClone();

    /// @notice Deploy one clone for this implementation/seed from the calling factory.
    /// @dev No initializer is called. Duplicate deployments revert. The seed is not
    ///      msg.sender unless the factory chooses it that way. Bind authorization in
    ///      your implementation to the embedded seed, never to whoever deploys it.
    function cloneDeterministic(address implementation, address seed)
        internal returns (address instance)
    {
        assembly ("memory-safe") {
            seed := and(seed, 0xffffffffffffffffffffffffffffffffffffffff)
            let ptr := mload(0x40)
            // Offsets: prefix [0,20), implementation [20,40), suffix [40,55), seed [55,75).
            mstore(ptr, 0x6100413d81600a3d39f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 20), shl(96, implementation))
            mstore(add(ptr, 40), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            mstore(add(ptr, 55), shl(96, seed))
            instance := create2(0, ptr, 75, seed)
        }
        if (instance == address(0)) revert DeploymentFailed();
    }

    /// @notice Predict without deploying or accessing storage/code.
    /// @dev The deployer is the address executing CREATE2 (the factory).
    function predictDeterministicAddress(address implementation, address seed, address deployer)
        internal pure returns (address predicted)
    {
        assembly ("memory-safe") {
            seed := and(seed, 0xffffffffffffffffffffffffffffffffffffffff)
            let ptr := mload(0x40)
            mstore(ptr, 0x6100413d81600a3d39f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 20), shl(96, implementation))
            mstore(add(ptr, 40), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            mstore(add(ptr, 55), shl(96, seed))
            let initCodeHash := keccak256(ptr, 75)
            // Reuse temporary memory for 0xff || deployer || padded seed || initCodeHash.
            mstore(ptr, shl(248, 0xff))
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), seed)
            mstore(add(ptr, 53), initCodeHash)
            predicted := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function predictDeterministicAddress(address implementation, address seed)
        internal view returns (address)
    {
        return predictDeterministicAddress(implementation, seed, address(this));
    }

    /// @notice Read the address from a deployed clone; reverts for wrong code size.
    /// @dev Size checking alone is NOT authentication. For untrusted external
    ///      addresses, use verifiedSeedOf with your trusted implementation/factory.
    ///      Inside the implementation, call seedOf(address(this)) through the clone.
    function seedOf(address instance) internal view returns (address seed) {
        if (instance.code.length != 65) revert UnexpectedCodeSize();
        assembly ("memory-safe") {
            // Scratch memory only. Bytes [45,65) are the packed seed.
            extcodecopy(instance, 0, 45, 20)
            seed := shr(96, mload(0))
        }
    }

    /// @notice Recover a seed AND confirm the canonical CREATE2 address.
    /// @dev implementation and deployer must be trusted inputs, not attacker claims.
    function verifiedSeedOf(address instance, address implementation, address deployer)
        internal view returns (address seed)
    {
        seed = seedOf(instance);
        if (predictDeterministicAddress(implementation, seed, deployer) != instance) {
            revert NotCanonicalClone();
        }
    }
}
