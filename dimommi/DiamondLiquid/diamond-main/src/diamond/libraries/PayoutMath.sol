// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PayoutMath
/// @notice The winning-close adjustment pipeline from whitepaper §5, in exact integer arithmetic.
/// @dev Order is fixed and must not be reordered: deadband -> holdback -> asymmetric impact haircut -> win fee.
///      Losses and liquidations never pass through this library's win path; a losing close pays no percentage fee.
///
///      Units
///      -----
///      * every ratio is WAD (1e18 == 1.0);
///      * notional, profit and margin are USDC base units (1e6);
///      * `referenceNotional` is stored WAD-dollars because whitepaper §5 divides it by 1e6 inside `term2`;
///      * `rateMultiplier` and `positionMultiplier` are the per-market calibration constants of §5.
///
///      Everything a market needs is passed in as `Calibration`, so no parameter is hard-coded for a market that has
///      not been reviewed: BTC/ETH carry the §5 benchmark values, every other market must be calibrated before it is
///      enabled (whitepaper §5: "keep it disabled until those parameters pass review").
library PayoutMath {
    using Math for uint256;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice Deadband: the exit is valued 0.2 bps (0.002% == entry/50,000) less favourably to the trader.
    uint256 internal constant DEADBAND_WAD = 2e13;

    /// @notice Standard payout curve: holdback band 0.75 bps .. 6 bps, peak ~1.2 bps near 3.4 bps.
    uint256 internal constant STD_BAND_START_WAD = 75e12; // 0.75 bps
    uint256 internal constant STD_BAND_END_WAD = 6e14; //   6.00 bps
    uint256 internal constant STD_K_WAD = 3.597e18;

    /// @notice Off-hours / weekend payout curve: band 0.3 bps .. 10 bps, peak ~2 bps near 4.2 bps.
    uint256 internal constant OFF_BAND_START_WAD = 3e13; // 0.30 bps
    uint256 internal constant OFF_BAND_END_WAD = 1e15; //  10.00 bps
    uint256 internal constant OFF_K_WAD = 6.085e18;

    /// @notice Which payout curve a close uses. A keeper publishes the active curve; one close uses exactly one curve.
    enum Curve {
        Standard,
        OffHours
    }

    /// @notice Per-market calibration of the §5 curve. Nothing here is shared across markets by default.
    struct Calibration {
        uint256 referenceNotionalWad; // fixed reference notional, controls curve steepness ($100,000e18 benchmark)
        uint64 rateMultiplier; // 15,000 for the BTC/ETH benchmark
        uint256 positionMultiplierWad; // 814.598 for BTC, 483.979 for ETH (benchmark only)
        uint16 baseRateBps; // 1,000 == 10%
        uint16 winFeeBps; // 199 == 1.99%
    }

    /// @notice Full audit trail of one winning close. Emitted nowhere; returned so the engine can log it.
    struct WinResult {
        uint256 moveWad; // post-deadband, post-holdback favourable move
        uint256 holdbackWad; // holdback taken from this move
        uint256 rawPnl; // notional * moveWad
        uint256 scaleWad; // impact scale in [0, 1e18]
        uint256 adjustedPnl; // rawPnl * scale
        uint256 winFee; // 1.99% of adjustedPnl
        uint256 netPnl; // what the trader is paid or queued
    }

    error InvalidCalibration();

    /// @notice Signed simple return `(p1 - p0) / p0` in WAD.
    function simpleReturn(uint256 p0, uint256 p1) internal pure returns (int256) {
        if (p0 == 0) return 0;
        return (int256(p1) - int256(p0)) * int256(WAD) / int256(p0);
    }

    /// @notice Favourable move for the position, in WAD. Zero when the move goes against the trader.
    /// @dev A long is favourable when price rises; a short when it falls.
    function favourableMoveWad(uint256 p0, uint256 p1, bool isLong) internal pure returns (uint256 move) {
        if (p0 == 0) return 0;
        if (isLong) {
            if (p1 <= p0) return 0;
            move = (p1 - p0) * WAD / p0;
        } else {
            if (p1 >= p0) return 0;
            move = (p0 - p1) * WAD / p0;
        }
    }

    /// @notice Adverse move for the position, in WAD. Zero when the move helps the trader.
    function adverseMoveWad(uint256 p0, uint256 p1, bool isLong) internal pure returns (uint256 move) {
        if (p0 == 0) return 0;
        if (isLong) {
            if (p1 >= p0) return 0;
            move = (p0 - p1) * WAD / p0;
        } else {
            if (p1 <= p0) return 0;
            move = (p1 - p0) * WAD / p0;
        }
    }

    /// @notice Holdback in WAD for a given absolute price move and curve.
    /// @dev standardHoldback = 3.597 * width * u^2 * (1-u)^2
    ///      offHoursHoldback = 6.085 * width * u^2 * (1-u)^3
    ///      with u = (priceMove - bandStart) / width, and zero outside the band.
    function holdbackWad(uint256 moveWad, Curve curve) internal pure returns (uint256) {
        uint256 bandStart;
        uint256 bandEnd;
        uint256 k;
        if (curve == Curve.Standard) {
            bandStart = STD_BAND_START_WAD;
            bandEnd = STD_BAND_END_WAD;
            k = STD_K_WAD;
        } else {
            bandStart = OFF_BAND_START_WAD;
            bandEnd = OFF_BAND_END_WAD;
            k = OFF_K_WAD;
        }
        if (moveWad <= bandStart || moveWad >= bandEnd) return 0;

        uint256 width = bandEnd - bandStart;
        uint256 u = (moveWad - bandStart) * WAD / width; // (0, 1e18)
        uint256 oneMinusU = WAD - u;
        uint256 u2 = u * u / WAD;
        uint256 tail = oneMinusU * oneMinusU / WAD;
        if (curve == Curve.OffHours) {
            tail = tail * oneMinusU / WAD;
        }
        // width * k has magnitude <= 1e15 * 6.085e18 / 1e18 ~= 6e15; the u^2 tail scales it down from there.
        return (width * k / WAD) * u2 / WAD * tail / WAD;
    }

    /// @notice Asymmetric impact scale: (1 - baseRate) / (1 + term1 + term2).
    /// @dev term1 = 1 / (move * rateMultiplier)
    ///      term2 = referenceNotional / (1e6 * move * positionMultiplier)
    ///      `move` is the post-deadband, post-holdback move (whitepaper §5 step 3). Impact alone retains at most
    ///      (1 - baseRate) of raw profit before the win fee.
    function impactScaleWad(uint256 moveWad, Calibration memory c) internal pure returns (uint256) {
        if (moveWad == 0 || c.rateMultiplier == 0 || c.positionMultiplierWad == 0) return 0;

        uint256 term1 = (WAD * WAD) / (moveWad * c.rateMultiplier);

        uint256 inner = moveWad * c.positionMultiplierWad / WAD; // move * positionMultiplier
        // referenceNotional / (1e6 * move * positionMultiplier), computed in one mulDiv so the 1e6 division cannot
        // truncate before the multiplication.
        uint256 term2 = inner == 0 ? type(uint256).max : Math.mulDiv(c.referenceNotionalWad, WAD, 1e6 * inner);

        // Saturate the additions instead of wrapping: `term2` can be `type(uint256).max` when the scaled move
        // rounds to zero, and `WAD + term1 + term2` would then overflow. A saturated denominator drives the scale
        // to zero, which is the intended economically-conservative outcome (the trader keeps nothing).
        uint256 denominator = WAD + term1;
        if (term2 > type(uint256).max - denominator) {
            denominator = type(uint256).max;
        } else {
            denominator += term2;
        }
        return (WAD - uint256(c.baseRateBps) * WAD / BPS) * WAD / denominator;
    }

    /// @notice Run the full winning-close pipeline.
    /// @param notional position notional in USDC base units (M * L)
    /// @param moveWad favourable move of the reference price, WAD
    /// @return r the pipeline result; all profit fields are zero when the deadband and holdback consume the move
    function win(uint256 notional, uint256 moveWad, Calibration memory c, Curve curve)
        internal
        pure
        returns (WinResult memory r)
    {
        if (c.rateMultiplier == 0 || c.positionMultiplierWad == 0 || c.baseRateBps > BPS || c.winFeeBps > BPS) {
            revert InvalidCalibration();
        }

        r.moveWad = moveWad;
        r.holdbackWad = holdbackWad(moveWad, curve);

        uint256 net = moveWad > DEADBAND_WAD + r.holdbackWad ? moveWad - DEADBAND_WAD - r.holdbackWad : 0;
        if (net == 0 || notional == 0) return r;

        r.moveWad = net;
        r.rawPnl = notional * net / WAD;
        r.scaleWad = impactScaleWad(net, c);
        r.adjustedPnl = r.rawPnl * r.scaleWad / WAD;
        r.winFee = r.adjustedPnl * uint256(c.winFeeBps) / BPS;
        r.netPnl = r.adjustedPnl - r.winFee;
    }

    /// @notice Loss for a losing close, capped at the position margin by the engine.
    function loss(uint256 notional, uint256 moveWad) internal pure returns (uint256) {
        return notional * moveWad / WAD;
    }
}
