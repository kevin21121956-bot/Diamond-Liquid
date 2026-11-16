// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Chainlink Data Streams VerifierProxy surface this protocol depends on.
/// @dev The proxy is the *only* component allowed to turn a signed payload into a report the protocol will read.
///      It validates the DON signature and routes to the correct verifier; it does NOT know anything about Diamond
///      Liquid's instrument mapping, freshness, deviation or risk limits. Those are enforced by the consumer
///      (see `DiamondLiquid._verifiedPrice`). Whitepaper §3.
///
///      Chainlink has shipped two call shapes over time; DiamondLiquid talks to an `IReportVerifier` adapter so the
///      deployment can pin whichever one the Arbitrum One proxy exposes.
interface IVerifierProxy {
    /// @param payload the full ABI-encoded signed report payload returned by the Data Streams API
    /// @param parameterPayload unused by the Data Streams proxy; kept for ABI compatibility
    /// @return the verified report body (signature stripped)
    function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory);
}

/// @notice Normalised verifier surface used by the protocol.
interface IReportVerifier {
    /// @notice Verify `payload` and return the report body, or revert.
    /// @dev Implementations MUST revert when the DON signature is missing, malformed or not from the configured DON.
    function verify(bytes calldata payload) external returns (bytes memory reportBody);
}
