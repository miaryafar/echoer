// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEchoerDataStore} from "./../interface/IEchoerDataStore.sol";

/*
 *                    E C H O E R   D A T A   S T O R E
 *
 *        Stores public bytes once and returns a compact bytes21 reference.
 *        Small values live inside the reference or one storage slot.
 *        Larger values live in deterministic, read-only contract bytecode.
 *
 *        Equal data receives the same reference.
 *        References are meaningful only with this DataStore.
 *        Nothing stored here is private, editable or removable.
 */

/// @title EchoerDataStore
/// @notice Permanent shared storage for Echoer messages and other data.
/// @dev The returned `bytes21` reference holds up to 20 bytes inline, points to
/// one storage slot for 21 to 32 bytes, or points to an inert data contract for
/// 33 to 24,575 bytes. Identical data reuses the same reference. There is no
/// owner, upgrade, or delete function. Treat references as opaque values made
/// by this contract.
contract EchoerDataStore is IEchoerDataStore {
    /// @notice Largest payload held directly inside a data reference.
    uint256 public constant INLINE_MAX_LENGTH = 20;

    /// @notice Smallest payload held in one packed contract storage slot.
    uint256 public constant PACKED_STORAGE_MIN_LENGTH = 21;

    /// @notice Largest payload held in one packed contract storage slot.
    uint256 public constant PACKED_STORAGE_MAX_LENGTH = 32;

    /// @notice Smallest payload stored in deterministic bytecode.
    uint256 public constant BYTECODE_MIN_LENGTH = 33;

    /// @notice Largest payload supported by one EIP-170-compatible data contract.
    uint256 public constant MAX_DATA_LENGTH = 24_575;

    /// @notice Type byte used by deterministic-bytecode references.
    uint8 public constant BYTECODE_REFERENCE_TYPE = 0x03;

    uint8 private constant INLINE_REFERENCE_BASE = 0x80;
    uint8 private constant INLINE_REFERENCE_MAX = 0x94;

    uint8 private constant PACKED_REFERENCE_BASE = 0x40;
    uint8 private constant PACKED_REFERENCE_MIN = 0x41;
    uint8 private constant PACKED_REFERENCE_MAX = 0x4c;

    bytes32 private constant DATA_SALT = bytes32(0);

    /// @dev For values of 21 to 32 bytes, the slot holds the left-aligned
    ///      payload and nothing else. The length lives in the reference.
    mapping(bytes20 key => bytes32 packedData) private _packedData;

    /// @notice The input exceeds the EIP-170-compatible maximum.
    error DataTooLarge(uint256 length);

    /// @notice CREATE2 did not return the address predicted for the data.
    error DataDeploymentFailed(bytes21 dataRef);

    /// @notice The deterministic address already contains different code.
    error DataAddressOccupied(address pointer);

    /// @notice A truncated packed-storage key maps to different data.
    error PackedDataKeyCollision(bytes20 key);

    /// @notice Reads a canonical reference, returning empty bytes when invalid.
    /// @dev Call `exists` when a valid zero-length value must be distinguished
    ///      from an invalid reference.
    function dataOf(
        bytes21 dataRef
    ) external view returns (bytes memory data) {
        (bool valid, bytes memory value) = _read(dataRef);
        if (!valid) return bytes("");
        return value;
    }

    /// @notice Reads a canonical reference as a Solidity string.
    /// @dev The stored length is the byte length supplied to `storeString`.
    function stringOf(
        bytes21 dataRef
    ) external view returns (string memory data) {
        (bool valid, bytes memory value) = _read(dataRef);
        if (!valid) return "";
        return string(value);
    }

    /// @notice Reads an inline or packed reference as a single left-aligned word.
    /// @dev Avoids the `bytes memory` allocation and ABI encode for on-chain
    ///      readers. Returns `valid == false` for bytecode references, which
    ///      cannot fit in one word, and for malformed references. Bytes past
    ///      `length` in `word` are always zero.
    function wordOf(
        bytes21 dataRef
    ) external view returns (bool valid, bytes32 word, uint256 length) {
        uint8 referenceType = _referenceType(dataRef);

        if (_isInlineType(referenceType)) {
            if (!_isCanonicalInline(dataRef, referenceType)) {
                return (false, bytes32(0), 0);
            }
            length = referenceType & 0x1f;
            word = bytes32(uint256(bytes32(dataRef)) << 8);
            return (true, _maskToLength(word, length), length);
        }

        if (_isPackedType(referenceType)) {
            length = _packedLength(referenceType);
            bytes20 key = _targetKey(dataRef);
            word = _packedData[key];
            if (!_packedMatchesKey(word, length, key)) {
                return (false, bytes32(0), 0);
            }
            return (true, _maskToLength(word, length), length);
        }

        return (false, bytes32(0), 0);
    }

    /// @notice Stores bytes and returns their canonical `bytes21` reference.
    /// @dev Repeated stores are idempotent. Inline values do not modify state.
    function store(
        bytes calldata data
    ) external returns (bytes21 dataRef) {
        return _store(data);
    }

    /// @notice Stores a string and returns its canonical `bytes21` reference.
    function storeString(
        string calldata data
    ) external returns (bytes21 dataRef) {
        return _store(bytes(data));
    }

    /// @notice Computes the canonical reference without writing storage.
    /// @dev For packed and bytecode values, `exists(dataRef)` may be false
    ///      until `store(data)` has been called. The one exception is an
    ///      all-zero packed payload, which needs no write.
    function referenceOf(
        bytes calldata data
    ) external view returns (bytes21 dataRef) {
        return _referenceOf(data);
    }

    /// @notice Computes the canonical reference for a string without storing it.
    function referenceOfString(
        string calldata data
    ) external view returns (bytes21 dataRef) {
        return _referenceOf(bytes(data));
    }

    /// @notice Returns the payload length, or zero for an invalid reference.
    /// @dev A valid empty inline value also has length zero; use `exists` to
    ///      distinguish those two cases.
    function dataLength(
        bytes21 dataRef
    ) external view returns (uint256 length) {
        uint8 referenceType = _referenceType(dataRef);

        if (_isInlineType(referenceType)) {
            if (!_isCanonicalInline(dataRef, referenceType)) return 0;
            return referenceType & 0x1f;
        }

        if (_isPackedType(referenceType)) {
            length = _packedLength(referenceType);
            bytes20 key = _targetKey(dataRef);
            if (!_packedMatchesKey(_packedData[key], length, key)) return 0;
            return length;
        }

        if (referenceType != BYTECODE_REFERENCE_TYPE) return 0;

        address pointer = _pointerOf(dataRef);
        uint256 codeLength = pointer.code.length;
        if (!_isDataCodeLength(codeLength)) return 0;
        if (!_hasDataCode(pointer)) return 0;
        return codeLength - 1;
    }

    /// @notice Returns whether a reference is canonical and backed by data.
    function exists(bytes21 dataRef) external view returns (bool) {
        uint8 referenceType = _referenceType(dataRef);

        if (_isInlineType(referenceType)) {
            return _isCanonicalInline(dataRef, referenceType);
        }

        if (_isPackedType(referenceType)) {
            bytes20 key = _targetKey(dataRef);
            return _packedMatchesKey(
                _packedData[key],
                _packedLength(referenceType),
                key
            );
        }

        if (referenceType != BYTECODE_REFERENCE_TYPE) return false;

        address pointer = _pointerOf(dataRef);
        if (!_isDataCodeLength(pointer.code.length)) return false;
        return _hasDataCode(pointer);
    }

    function _store(
        bytes calldata data
    ) private returns (bytes21 dataRef) {
        uint256 length = data.length;
        if (length > MAX_DATA_LENGTH) revert DataTooLarge(length);
        if (length <= INLINE_MAX_LENGTH) return _inlineReference(data);

        if (length <= PACKED_STORAGE_MAX_LENGTH) {
            bytes20 key = bytes20(keccak256(data));
            bytes32 packedWord = _packWord(data);
            bytes32 existingWord = _packedData[key];

            if (existingWord != packedWord) {
                // Repeated data and an all-zero payload need no write.
                if (existingWord != bytes32(0)) {
                    revert PackedDataKeyCollision(key);
                }
                _packedData[key] = packedWord;
            }

            return _packedReference(length, key);
        }

        bytes memory initCode = _creationCode(data);
        address pointer = _create2Address(keccak256(initCode));

        dataRef = _targetReference(
            BYTECODE_REFERENCE_TYPE,
            uint160(pointer)
        );

        uint256 existingCodeLength = pointer.code.length;
        if (existingCodeLength != 0) {
            // Confirm that an existing data contract contains this payload.
            if (
                existingCodeLength != length + 1
                    || pointer.codehash != _runtimeCodeHash(initCode, length)
            ) {
                revert DataAddressOccupied(pointer);
            }
            return dataRef;
        }

        address deployed;
        assembly ("memory-safe") {
            // Literal zero is the same value as DATA_SALT.
            deployed := create2(
                0,
                add(initCode, 0x20),
                mload(initCode),
                0
            )
        }

        if (deployed != pointer) revert DataDeploymentFailed(dataRef);
    }

    function _referenceOf(
        bytes calldata data
    ) private view returns (bytes21 dataRef) {
        uint256 length = data.length;
        if (length > MAX_DATA_LENGTH) revert DataTooLarge(length);
        if (length <= INLINE_MAX_LENGTH) return _inlineReference(data);

        if (length <= PACKED_STORAGE_MAX_LENGTH) {
            return _packedReference(length, bytes20(keccak256(data)));
        }

        bytes memory initCode = _creationCode(data);
        address pointer = _create2Address(keccak256(initCode));
        return _targetReference(BYTECODE_REFERENCE_TYPE, uint160(pointer));
    }

    function _read(
        bytes21 dataRef
    ) private view returns (bool valid, bytes memory data) {
        uint8 referenceType = _referenceType(dataRef);

        if (_isInlineType(referenceType)) {
            if (!_isCanonicalInline(dataRef, referenceType)) {
                return (false, bytes(""));
            }
            return (true, _inlineData(dataRef, referenceType));
        }

        if (_isPackedType(referenceType)) {
            uint256 packedLength = _packedLength(referenceType);
            bytes20 key = _targetKey(dataRef);
            bytes32 packedWord = _packedData[key];
            if (!_packedMatchesKey(packedWord, packedLength, key)) {
                return (false, bytes(""));
            }
            return (true, _unpackData(packedWord, packedLength));
        }

        if (referenceType != BYTECODE_REFERENCE_TYPE) {
            return (false, bytes(""));
        }

        address pointer = _pointerOf(dataRef);
        uint256 codeLength = pointer.code.length;
        if (!_isDataCodeLength(codeLength)) return (false, bytes(""));
        if (!_hasDataCode(pointer)) return (false, bytes(""));

        uint256 length = codeLength - 1;
        data = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, length)
        }
        return (true, data);
    }

    function _creationCode(
        bytes calldata data
    ) private pure returns (bytes memory initCode) {
        // Creation instructions before the runtime (10 bytes):
        // PUSH2 runtimeLength | DUP1 | PUSH1 0x0a | RETURNDATASIZE |
        // CODECOPY | RETURNDATASIZE | RETURN. The trailing 0x00 is the
        // first runtime byte (STOP), so the runtime starts at offset 0x0a.
        // Runtime code: STOP | data
        return abi.encodePacked(
            hex"61",
            bytes2(uint16(data.length + 1)),
            hex"80600A3D393DF300",
            data
        );
    }

    function _runtimeCodeHash(
        bytes memory initCode,
        uint256 dataLength_
    ) private pure returns (bytes32 codeHash) {
        assembly ("memory-safe") {
            codeHash := keccak256(add(initCode, 0x2a), add(dataLength_, 1))
        }
    }

    function _create2Address(
        bytes32 initCodeHash
    ) private view returns (address pointer) {
        pointer = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            DATA_SALT,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    function _inlineReference(
        bytes calldata data
    ) private pure returns (bytes21 dataRef) {
        uint256 length = data.length;
        uint256 dataWord;
        assembly ("memory-safe") {
            dataWord := calldataload(data.offset)
        }

        uint256 payload = dataWord >> 8;
        uint256 unusedBits = (31 - length) * 8;
        payload = (payload >> unusedBits) << unusedBits;

        return bytes21(
            bytes32(
                (uint256(INLINE_REFERENCE_BASE | uint8(length)) << 248)
                    | payload
            )
        );
    }

    function _inlineData(
        bytes21 dataRef,
        uint8 referenceType
    ) private pure returns (bytes memory data) {
        uint256 length = referenceType & 0x1f;
        uint256 referenceWord = uint256(bytes32(dataRef));
        data = new bytes(length);
        assembly ("memory-safe") {
            mstore(add(data, 0x20), shl(8, referenceWord))
        }
    }

    /// @dev Left-aligned payload, zero-filled past `length`. No length byte.
    function _packWord(
        bytes calldata data
    ) private pure returns (bytes32 packedWord) {
        uint256 length = data.length;
        uint256 dataWord;
        assembly ("memory-safe") {
            dataWord := calldataload(data.offset)
        }
        return _maskToLength(bytes32(dataWord), length);
    }

    function _unpackData(
        bytes32 packedWord,
        uint256 length
    ) private pure returns (bytes memory data) {
        data = new bytes(length);
        assembly ("memory-safe") {
            mstore(add(data, 0x20), packedWord)
        }
    }

    /// @dev Confirms the slot holds the payload the reference names. An
    ///      untouched slot only passes for an all-zero payload, which is
    ///      exactly the payload that needs no write.
    function _packedMatchesKey(
        bytes32 packedWord,
        uint256 length,
        bytes20 key
    ) private pure returns (bool matches) {
        bytes32 contentHash;
        assembly ("memory-safe") {
            // Scratch space, 0x00 to 0x3f, holds one word; `length` is at
            // most 32 by construction of the packed reference range.
            mstore(0x00, packedWord)
            contentHash := keccak256(0x00, length)
        }
        return bytes20(contentHash) == key;
    }

    function _maskToLength(
        bytes32 word,
        uint256 length
    ) private pure returns (bytes32 masked) {
        if (length == 32) return word;
        uint256 unusedBits = (32 - length) * 8;
        return bytes32((uint256(word) >> unusedBits) << unusedBits);
    }

    function _packedReference(
        uint256 length,
        bytes20 key
    ) private pure returns (bytes21 dataRef) {
        return _targetReference(
            uint8(PACKED_REFERENCE_BASE | (length - INLINE_MAX_LENGTH)),
            uint160(key)
        );
    }

    function _targetReference(
        uint8 referenceType,
        uint160 target
    ) private pure returns (bytes21 dataRef) {
        return bytes21(
            bytes32(
                (uint256(referenceType) << 248)
                    | (uint256(target) << 88)
            )
        );
    }

    function _isDataCodeLength(
        uint256 codeLength
    ) private pure returns (bool) {
        return
            codeLength >= BYTECODE_MIN_LENGTH + 1
                && codeLength <= MAX_DATA_LENGTH + 1;
    }

    function _hasDataCode(
        address pointer
    ) private view returns (bool valid) {
        uint256 firstByte;
        assembly ("memory-safe") {
            extcodecopy(pointer, 0x00, 0, 1)
            firstByte := byte(0, mload(0x00))
        }
        return firstByte == 0;
    }

    function _isCanonicalInline(
        bytes21 dataRef,
        uint8 referenceType
    ) private pure returns (bool canonical) {
        uint256 length = referenceType & 0x1f;
        uint256 unusedBits = (31 - length) * 8;
        uint256 unusedMask = (uint256(1) << unusedBits) - 1;
        return (uint256(bytes32(dataRef)) & unusedMask) == 0;
    }

    function _referenceType(
        bytes21 dataRef
    ) private pure returns (uint8 referenceType) {
        return uint8(uint256(bytes32(dataRef)) >> 248);
    }

    function _packedLength(
        uint8 referenceType
    ) private pure returns (uint256 length) {
        return INLINE_MAX_LENGTH + (referenceType & 0x1f);
    }

    function _targetKey(
        bytes21 dataRef
    ) private pure returns (bytes20 key) {
        return bytes20(uint160(uint256(bytes32(dataRef)) >> 88));
    }

    function _pointerOf(
        bytes21 dataRef
    ) private pure returns (address pointer) {
        return address(uint160(uint256(bytes32(dataRef)) >> 88));
    }

    function _isInlineType(uint8 referenceType) private pure returns (bool) {
        return
            referenceType >= INLINE_REFERENCE_BASE
                && referenceType <= INLINE_REFERENCE_MAX;
    }

    function _isPackedType(uint8 referenceType) private pure returns (bool) {
        return
            referenceType >= PACKED_REFERENCE_MIN
                && referenceType <= PACKED_REFERENCE_MAX;
    }
}
