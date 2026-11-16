// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice The one engine fact the registry needs: whether a market carries live risk.
interface IOpenInterest {
    function marketOpenNotional(uint16 marketId) external view returns (uint256);
}

/// @title MarketRegistry
/// @notice The per-market deployment registry required by whitepaper §2 and §7.
/// @dev Every market starts disabled and stays disabled until its exact Chainlink stream id, schema, quote currency,
///      verifier route, hours/status rules, freshness/deviation limits, calibration and risk limits have been recorded
///      here. Ticker text is metadata only: `symbol` is never used for pricing, routing or risk.
///
///      What this contract deliberately does NOT do is claim any market is available on Arbitrum One. Registering a row
///      (even with a stream id) proves nothing about Data Streams entitlement or report availability — that is verified
///      off chain per whitepaper §2/§3 and only then expressed as `setEnabled(id, true)`.
contract MarketRegistry is Ownable {
    uint16 public constant PROTOCOL_MAX_LEVERAGE = 1000;

    /// @notice One roster row. `schema` selects the report body shape decoded in `ReportLib`.
    struct Market {
        string symbol; // display only, never an identity
        bytes32 streamId; // exact Data Streams report id (0 == not yet verified)
        bytes32 fxStreamId; // non-USD quote: explicit conversion stream (0 == USD quoted)
        uint8 schema; // 0 = single-feed body, 1 = bundle body
        uint8 statusScheme; // 0 = price-only payload; 1 = payload carries a market-status field (unsupported, see below)
        uint16 bundleIndex; // index inside a bundle body
        uint8 priceDecimals; // decimals of the reported price
        uint32 maxAgeSeconds; // freshness limit for settlement use
        uint32 maxFutureSkewSeconds; // tolerance for a report timestamp ahead of block time
        uint16 maxDeviationBps; // move allowed versus the last accepted price
        uint16 maintenanceMarginBps; // maintenance margin, of notional
        uint16 minLeverage;
        uint16 maxLeverage;
        uint256 maxOpenNotional; // per market, USDC base units
        uint256 maxAccountNotional; // per account, USDC base units
        uint32 sessionOpenMinute; // minutes after 00:00 UTC
        uint32 sessionCloseMinute;
        uint8 tradingDaysMask; // bit0 = Monday ... bit6 = Sunday; overnight windows use their starting day
        bool sessionBound; // false == 24/7
        bool enabled;
        bool halted;
        uint32 minDuration;
        uint32 maxDuration;
        // §5 payout calibration — never inherited from another market
        uint128 referenceNotionalWad;
        uint64 rateMultiplier;
        uint128 positionMultiplierWad;
        uint16 baseRateBps;
        uint16 winFeeBps;
    }

    Market[] private _markets;

    /// @notice The engine whose open interest gates configuration changes. Set once, after deployment.
    address public engine;

    event MarketAdded(uint16 indexed marketId, string symbol);
    event MarketEnabled(uint16 indexed marketId, bool enabled);
    event MarketHalted(uint16 indexed marketId, bool halted);
    event EngineSet(address indexed engine);
    event StatusSchemeUpdated(uint16 indexed marketId, uint8 statusScheme);
    event StreamUpdated(
        uint16 indexed marketId, bytes32 streamId, bytes32 fxStreamId, uint8 schema, uint16 bundleIndex
    );
    event LimitsUpdated(uint16 indexed marketId, uint16 maxLeverage, uint256 maxOpenNotional);
    event CalibrationUpdated(uint16 indexed marketId, uint128 referenceNotionalWad, uint64 rateMultiplier);
    event SessionUpdated(uint16 indexed marketId, bool sessionBound, uint32 openMinute, uint32 closeMinute);

    error InvalidMarket();
    error MarketMissing();
    error UnverifiedStream();
    error UnverifiedCalibration();
    error BadParameter();
    error MarketHasOpenPositions();
    error StatusSchemeUnsupported();
    error EngineAlreadySet();

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ------------------------------------------------------------------ views

    function count() external view returns (uint256) {
        return _markets.length;
    }

    function market(uint16 marketId) external view returns (Market memory) {
        if (marketId >= _markets.length) revert MarketMissing();
        return _markets[marketId];
    }

    /// @notice Whether the market's configured trading calendar is open at `timestamp`.
    /// @dev Calendar is configuration, not a price source: the price still has to come from a fresh verified report.
    function isOpenAt(uint16 marketId, uint256 timestamp) public view returns (bool) {
        if (marketId >= _markets.length) revert MarketMissing();
        Market storage m = _markets[marketId];
        if (!m.sessionBound) return true;

        // Bit packing: 24/7 session windows are expressed with sessionBound == false instead.
        uint256 minute = (timestamp % 1 days) / 60;
        uint256 weekday = (timestamp / 1 days + 3) % 7; // 1970-01-01 was a Thursday; 0 == Monday

        uint32 openMinute = m.sessionOpenMinute;
        uint32 closeMinute = m.sessionCloseMinute;
        if (closeMinute > openMinute) {
            return m.tradingDaysMask & (1 << weekday) != 0 && minute >= openMinute && minute < closeMinute;
        }
        // A wrapping window belongs to the day on which it starts; after midnight, consult the previous day.
        if (minute >= openMinute) return m.tradingDaysMask & (1 << weekday) != 0;
        if (minute < closeMinute) return m.tradingDaysMask & (1 << ((weekday + 6) % 7)) != 0;
        return false;
    }

    // ------------------------------------------------------------------ admin

    /// @notice Register a new roster row. It is created disabled regardless of any other field.
    function addMarket(Market memory config) external onlyOwner returns (uint16 marketId) {
        _validate(config);
        marketId = uint16(_markets.length);
        Market memory copy = config;
        copy.enabled = false;
        _markets.push(copy);
        emit MarketAdded(marketId, config.symbol);
    }

    /// @notice Enable or disable a market.
    /// @dev Enabling requires a recorded stream id: a row cannot go live on a ticker alone.
    function setEnabled(uint16 marketId, bool enabled) external onlyOwner {
        Market storage m = _market(marketId);
        if (enabled) {
            if (m.streamId == bytes32(0)) revert UnverifiedStream();
            // A market cannot go live on a stream id alone: its §5 calibration must have been reviewed too.
            if (m.rateMultiplier == 0 || m.positionMultiplierWad == 0) revert UnverifiedCalibration();
            if (m.halted) revert BadParameter();
            // A payload whose fields include a market-status word does not fit the price/bid/ask decoder in
            // `ReportLib`. Until a decoder for that exact schema exists, such a market cannot be enabled — the
            // contract refuses rather than letting a crypto-shaped decode read a status code as a price.
            if (m.statusScheme != 0) revert StatusSchemeUnsupported();
        }
        m.enabled = enabled;
        emit MarketEnabled(marketId, enabled);
    }

    function setHalted(uint16 marketId, bool halted) external onlyOwner {
        Market storage m = _market(marketId);
        m.halted = halted;
        emit MarketHalted(marketId, halted);
    }

    /// @notice Point at the engine whose open interest gates configuration changes.
    /// @dev Set once after deployment. While `engine` is unset the guards are inert, which is only ever true before
    ///      the first position can exist.
    function setEngine(address engine_) external onlyOwner {
        if (engine != address(0)) revert EngineAlreadySet();
        if (engine_.code.length == 0) revert BadParameter();
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Declare whether a market's payload carries a market-status word.
    /// @dev `1` means "the feed encodes status alongside price" — the price/bid/ask decoder does not model that layout,
    ///      so the market cannot be enabled while it is set.
    function setStatusScheme(uint16 marketId, uint8 statusScheme) external onlyOwner {
        if (statusScheme > 1) revert BadParameter();
        _requireNoOpenInterest(marketId);
        Market storage m = _market(marketId);
        if (m.enabled) revert BadParameter();
        m.statusScheme = statusScheme;
        emit StatusSchemeUpdated(marketId, statusScheme);
    }

    /// @notice Pin the exact stream identity once it has been verified for Arbitrum One.
    /// @dev Refused while the market carries open risk: an open position must not change its price source under itself.
    function setStream(
        uint16 marketId,
        bytes32 streamId,
        bytes32 fxStreamId,
        uint8 schema,
        uint16 bundleIndex,
        uint8 priceDecimals
    ) external onlyOwner {
        if (schema > 1 || priceDecimals > 30) revert BadParameter();
        _requireNoOpenInterest(marketId);
        Market storage m = _market(marketId);
        m.streamId = streamId;
        m.fxStreamId = fxStreamId;
        m.schema = schema;
        m.bundleIndex = bundleIndex;
        m.priceDecimals = priceDecimals;
        emit StreamUpdated(marketId, streamId, fxStreamId, schema, bundleIndex);
    }

    /// @notice Update the risk envelope. Never raises a market above the protocol leverage ceiling.
    /// @dev Also rejects any configuration in which a fresh position is liquidatable the moment it opens:
    ///      equity at open equals the posted margin, and liquidation requires equity <= maintenanceMargin * notional,
    ///      so maxLeverage * maintenanceMarginBps must stay strictly below 10_000 bps.
    function setLimits(
        uint16 marketId,
        uint16 minLeverage,
        uint16 maxLeverage,
        uint16 maintenanceMarginBps,
        uint16 maxDeviationBps,
        uint32 maxAgeSeconds,
        uint32 maxFutureSkewSeconds,
        uint256 maxOpenNotional,
        uint256 maxAccountNotional
    ) external onlyOwner {
        if (
            maxLeverage == 0 || maxLeverage > PROTOCOL_MAX_LEVERAGE || minLeverage == 0 || minLeverage > maxLeverage
                || maintenanceMarginBps >= 10_000 || maxDeviationBps == 0 || maxDeviationBps > 10_000
                || maxAgeSeconds == 0 || uint256(maxLeverage) * maintenanceMarginBps >= 10_000
        ) revert BadParameter();
        _requireNoOpenInterest(marketId);

        Market storage m = _market(marketId);
        m.minLeverage = minLeverage;
        m.maxLeverage = maxLeverage;
        m.maintenanceMarginBps = maintenanceMarginBps;
        m.maxDeviationBps = maxDeviationBps;
        m.maxAgeSeconds = maxAgeSeconds;
        m.maxFutureSkewSeconds = maxFutureSkewSeconds;
        m.maxOpenNotional = maxOpenNotional;
        m.maxAccountNotional = maxAccountNotional;
        emit LimitsUpdated(marketId, maxLeverage, maxOpenNotional);
    }

    /// @notice Update the §5 payout calibration for one market.
    function setCalibration(
        uint16 marketId,
        uint128 referenceNotionalWad,
        uint64 rateMultiplier,
        uint128 positionMultiplierWad,
        uint16 baseRateBps,
        uint16 winFeeBps
    ) external onlyOwner {
        if (rateMultiplier == 0 || positionMultiplierWad == 0 || baseRateBps > 10_000 || winFeeBps > 10_000) {
            revert BadParameter();
        }
        // Positions snapshot their own terms at open (`DiamondLiquid.terms`), but a live market must not be repriced
        // either: the change would apply to every new position on a book whose old positions still settle.
        _requireNoOpenInterest(marketId);
        Market storage m = _market(marketId);
        m.referenceNotionalWad = referenceNotionalWad;
        m.rateMultiplier = rateMultiplier;
        m.positionMultiplierWad = positionMultiplierWad;
        m.baseRateBps = baseRateBps;
        m.winFeeBps = winFeeBps;
        emit CalibrationUpdated(marketId, referenceNotionalWad, rateMultiplier);
    }

    /// @notice Update the trading calendar for one market.
    function setSession(
        uint16 marketId,
        bool sessionBound,
        uint32 openMinute,
        uint32 closeMinute,
        uint8 tradingDaysMask
    ) external onlyOwner {
        if (openMinute >= 1440 || closeMinute >= 1440) revert BadParameter();
        _requireNoOpenInterest(marketId);
        Market storage m = _market(marketId);
        m.sessionBound = sessionBound;
        m.sessionOpenMinute = openMinute;
        m.sessionCloseMinute = closeMinute;
        m.tradingDaysMask = tradingDaysMask;
        emit SessionUpdated(marketId, sessionBound, openMinute, closeMinute);
    }

    /// @notice Allowed trade durations for one market.
    function setDurations(uint16 marketId, uint32 minDuration, uint32 maxDuration) external onlyOwner {
        if (minDuration == 0 || maxDuration < minDuration) revert BadParameter();
        _requireNoOpenInterest(marketId);
        Market storage m = _market(marketId);
        m.minDuration = minDuration;
        m.maxDuration = maxDuration;
    }

    // ------------------------------------------------------------------ internal

    /// @dev A market with live risk cannot have its identity, envelope, calendar or calibration rewritten.
    function _requireNoOpenInterest(uint16 marketId) internal view {
        address engine_ = engine;
        if (engine_ != address(0) && IOpenInterest(engine_).marketOpenNotional(marketId) != 0) {
            revert MarketHasOpenPositions();
        }
    }

    function _market(uint16 marketId) internal view returns (Market storage m) {
        if (marketId >= _markets.length) revert MarketMissing();
        m = _markets[marketId];
    }

    function _validate(Market memory c) internal pure {
        if (
            c.maxLeverage == 0 || c.maxLeverage > PROTOCOL_MAX_LEVERAGE || c.minLeverage == 0
                || c.minLeverage > c.maxLeverage || c.maintenanceMarginBps >= 10_000 || c.maxDeviationBps == 0
                || c.maxAgeSeconds == 0 || c.baseRateBps > 10_000 || c.winFeeBps > 10_000 || c.priceDecimals > 30
                || c.schema > 1 || c.statusScheme > 1
                || uint256(c.maxLeverage) * c.maintenanceMarginBps >= 10_000
        ) revert BadParameter();
        if (c.sessionBound && (c.sessionOpenMinute >= 1440 || c.sessionCloseMinute >= 1440)) revert BadParameter();
        if (c.minDuration == 0 || c.maxDuration < c.minDuration) revert BadParameter();
    }
}
