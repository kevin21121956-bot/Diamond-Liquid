// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Revenue hook used by the House Pool to tell the reward distributor how much *actual* cash was collected.
/// @dev Whitepaper §6: `BuybackEligibleCashUSD(e) = 0.0099 * SettledLossProceedsUSD(e) + CollectedWinFeeCash(e)`.
///      Only collected cash counts; a queued (unpaid) winning claim contributes nothing.
interface ILossRewardDistributor {
    function recordRevenue(uint256 winFeeCash, uint256 lossBuybackCash) external;
}
