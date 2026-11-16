// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DiamondLiquid} from "./DiamondLiquid.sol";

/// @title CrePositionForwarder
/// @notice The consumer half of a Chainlink CRE onchain-write workflow (whitepaper §3).
/// @dev Two different signatures guard two different things, and neither substitutes for the other:
///
///        1. the CRE *KeystoneForwarder* proves a workflow report is authentic and delivered by an enabled workflow —
///           that is the `msg.sender` check here;
///        2. the Data Streams *VerifierProxy* proves the market report embedded in that workflow report is a genuine
///           signed Chainlink report — that check happens inside `DiamondLiquid`, after this contract forwards the
///           payload untouched.
///
///      A workflow report carries no price authority of its own. This contract cannot set a price, skip a gate or settle
///      anything that `DiamondLiquid` would not accept from a plain EOA: it only supplies calldata.
///
///      Workflow report layout (ABI):
///        (address trader, DiamondLiquid.OpenParams params, bytes dataStreamsPayload, bytes fxPayload)
contract CrePositionForwarder {
    /// @notice The Chainlink KeystoneForwarder enabled for this consumer.
    address public immutable keystoneForwarder;
    DiamondLiquid public immutable engine;

    event CrePositionOpened(address indexed trader, uint256 positionId, address indexed forwarder);

    error NotKeystoneForwarder();
    error ZeroAddress();

    constructor(address keystoneForwarder_, DiamondLiquid engine_) {
        if (keystoneForwarder_ == address(0) || address(engine_) == address(0)) revert ZeroAddress();
        keystoneForwarder = keystoneForwarder_;
        engine = engine_;
    }

    /// @notice Entry point used by the KeystoneForwarder (`IReceiver.onReport`).
    function onReport(bytes calldata, bytes calldata report) external returns (uint256 positionId) {
        if (msg.sender != keystoneForwarder) revert NotKeystoneForwarder();

        (address trader, DiamondLiquid.OpenParams memory params, bytes memory streamsPayload, bytes memory fxPayload) =
            abi.decode(report, (address, DiamondLiquid.OpenParams, bytes, bytes));

        // The engine validates the embedded Data Streams report through the VerifierProxy, then applies freshness,
        // market-status, leverage, capacity, pool and calibration gates exactly as for a user-submitted transaction.
        positionId = engine.openPositionFor(trader, params, streamsPayload, fxPayload);

        emit CrePositionOpened(trader, positionId, msg.sender);
    }
}
