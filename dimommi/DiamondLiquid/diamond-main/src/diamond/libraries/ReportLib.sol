// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReportLib
/// @notice Decoding helpers for Chainlink Data Streams reports.
/// @dev Real Data Streams full reports contain a header, report body and DON signatures in an ABI-encoded payload;
///      the real VerifierProxy verifies that payload and returns the body. The local mock instead uses a simplified
///      `body || signature` envelope and does not model DON verification or real payload encoding.
///      `Report` models Chainlink's v3 crypto body. `Bundle` is a local experimental column-array shape, not a
///      verified claim about the Data Streams API; the production adapter rejects all but single-feed v3 bodies.
library ReportLib {
    error ReportTooShort();
    error SignatureMissing();
    error InvalidSignature();
    error BundleIndexOutOfRange();

    /// @notice The fields Diamond Liquid reads from a verified report.
    /// @dev Mirrors Chainlink's published single-report struct. Extra schema fields a deployment may need (for example
    ///      the market-status bytes carried by RWA/equity reports) are intentionally NOT guessed here: a market that
    ///      requires them stays disabled until a decoder for that exact schema is reviewed (whitepaper §2, §7).
    struct Report {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        int192 bid;
        int192 ask;
    }

    /// @notice Column-array ("bundle") body of a Data Streams report.
    struct Bundle {
        bytes32[] feedIds;
        uint32[] validFromTimestamps;
        int192[] observations;
        int192[] bids;
        int192[] asks;
        uint32[] observationsTimestamps;
        uint192[] nativeFees;
        uint192[] linkFees;
        uint32[] expiresAt;
    }

    uint256 internal constant SIG_LENGTH = 65;

    /// @notice Split the simplified LOCAL MOCK payload into body and trailing single-signer signature.
    function split(bytes calldata payload) internal pure returns (bytes calldata body, bytes calldata sig) {
        if (payload.length <= SIG_LENGTH) revert SignatureMissing();
        unchecked {
            body = payload[:payload.length - SIG_LENGTH];
            sig = payload[payload.length - SIG_LENGTH:];
        }
    }

    /// @notice Recover the local mock signer of `digest` from a 65-byte `(r, s, v)` signature.
    /// @dev Rejects high-s malleable signatures so a caller cannot mutate a valid payload into a second valid one.
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        if (sig.length != SIG_LENGTH) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // EIP-2: only the lower half of the secp256k1 order is a valid signature scalar.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }
        if (v != 27 && v != 28) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    /// @notice Decode a single-feed report body.
    function decodeSingle(bytes memory body) internal pure returns (Report memory report) {
        if (body.length < 9 * 32) revert ReportTooShort();
        report = abi.decode(body, (Report));
    }

    /// @notice Decode the `index`-th feed out of a column-array bundle body.
    function decodeBundleAt(bytes memory body, uint256 index) internal pure returns (Report memory report) {
        if (body.length < 9 * 32) revert ReportTooShort();
        Bundle memory bundle = abi.decode(body, (Bundle));
        if (index >= bundle.feedIds.length) revert BundleIndexOutOfRange();
        // Every column must be at least as long as the feed-id column: a truncated report must not decode.
        if (
            bundle.observations.length <= index || bundle.bids.length <= index || bundle.asks.length <= index
                || bundle.observationsTimestamps.length <= index || bundle.validFromTimestamps.length <= index
                || bundle.nativeFees.length <= index || bundle.linkFees.length <= index
                || bundle.expiresAt.length <= index
        ) revert ReportTooShort();

        report = Report({
            feedId: bundle.feedIds[index],
            validFromTimestamp: bundle.validFromTimestamps[index],
            observationsTimestamp: bundle.observationsTimestamps[index],
            nativeFee: bundle.nativeFees[index],
            linkFee: bundle.linkFees[index],
            expiresAt: bundle.expiresAt[index],
            price: bundle.observations[index],
            bid: bundle.bids[index],
            ask: bundle.asks[index]
        });
    }

    /// @notice Body hash, recorded on chain as report provenance for each position leg.
    function bodyHash(bytes memory body) internal pure returns (bytes32) {
        return keccak256(body);
    }
}
