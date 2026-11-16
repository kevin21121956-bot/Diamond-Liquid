// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReportVerifier} from "../interfaces/IVerifierProxy.sol";
import {ReportLib} from "../libraries/ReportLib.sol";

/// @title MockVerifierProxy
/// @notice Local stand-in for the Chainlink Data Streams VerifierProxy.
/// @dev The mock envelope is `body || 65-byte signature` (not the real full-report format), and the
///      mock returns the body only when the signature recovers to the configured local signer. It deliberately does NOT
///      check freshness, feed identity, deviation or anything else — that separation is precisely what whitepaper §3
///      insists on, and the tests prove the engine re-checks all of it even with a valid signature.
///
///      Local report layout:  abi.encode(ReportLib.Report) ++ r ++ s ++ v, signed over keccak256(body).
contract MockVerifierProxy is IReportVerifier, Ownable {
    address public donSigner;
    bool public paused;
    uint256 public verifiedReports;

    mapping(bytes32 => bool) public seenBodyHashes;

    event DonSignerSet(address signer);
    event ReportVerified(bytes32 indexed bodyHash, address signer, uint256 bodyLength);
    event ProxyPaused(bool paused);

    error ProxyIsPaused();
    error UnknownSigner(address recovered);
    error EmptyReport();

    constructor(address donSigner_, address initialOwner) Ownable(initialOwner) {
        donSigner = donSigner_;
    }

    function setDonSigner(address signer) external onlyOwner {
        donSigner = signer;
        emit DonSignerSet(signer);
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit ProxyPaused(value);
    }

    /// @inheritdoc IReportVerifier
    function verify(bytes calldata payload) external returns (bytes memory reportBody) {
        if (paused) revert ProxyIsPaused();

        (bytes calldata body, bytes calldata signature) = ReportLib.split(payload);
        if (body.length == 0) revert EmptyReport();

        bytes32 digest = keccak256(body);
        address signer = ReportLib.recover(digest, signature);
        if (signer != donSigner) revert UnknownSigner(signer);

        verifiedReports += 1;
        seenBodyHashes[digest] = true;
        emit ReportVerified(digest, signer, body.length);

        // calldata -> memory copy; the engine then decodes and validates every field itself.
        reportBody = body;
    }
}
