// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVerifierProxy, IReportVerifier} from "./interfaces/IVerifierProxy.sol";

/// @title VerifierProxyAdapter
/// @notice Bridges the deployed Chainlink Data Streams VerifierProxy onto the protocol's `IReportVerifier` surface.
/// @dev Research adapter for the current subscription-billed VerifierProxy API. It sends empty fee metadata and
///      zero native currency. Only a verified single-feed v3 crypto body is accepted; the engine does not yet
///      implement status-aware RWA schemas. This is not evidence of actual Arbitrum entitlement or integration.
contract VerifierProxyAdapter is IReportVerifier {
    IVerifierProxy public immutable proxy;
    address public immutable operator;

    event Funded(address indexed from, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    error NotOperator();
    error ZeroAddress();
    error UnsupportedVerifiedReport();

    constructor(IVerifierProxy proxy_, address operator_) {
        if (address(proxy_) == address(0) || operator_ == address(0)) revert ZeroAddress();
        proxy = proxy_;
        operator = operator_;
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Forward a full report to the real VerifierProxy and return the verified body.
    function verify(bytes calldata payload) external returns (bytes memory) {
        bytes memory body = proxy.verify(payload, "");
        // Chainlink embeds schema version in the first two bytes of the verified feed ID. Check *after*
        // verification, not a caller-controlled header; the engine currently only understands v3 fields.
        if (body.length != 9 * 32 || uint8(body[0]) != 0 || uint8(body[1]) != 3) {
            revert UnsupportedVerifiedReport();
        }
        return body;
    }

    /// @notice Recover any unspent fee balance.
    function sweep(address to) external {
        if (msg.sender != operator) revert NotOperator();
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        (bool ok,) = to.call{value: balance}("");
        require(ok, "sweep");
        emit Swept(to, balance);
    }
}
