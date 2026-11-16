// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {HousePool} from "./HousePool.sol";
import {LossRewardDistributor} from "./LossRewardDistributor.sol";
import {IReportVerifier} from "./interfaces/IVerifierProxy.sol";
import {ReportLib} from "./libraries/ReportLib.sol";
import {PayoutMath} from "./libraries/PayoutMath.sol";

/// @title DiamondLiquid
/// @notice USDC-margined synthetic long/short engine for Arbitrum One (whitepaper §1, §4, §5).
/// @dev The single external price source is a Chainlink Data Streams report. Every state-changing price use runs the
///      same pipeline:
///
///        1. the full signed report is handed to the VerifierProxy, which validates the DON signature;
///        2. the body is decoded and the *application* re-checks feed id, schema, decimals, positivity, freshness,
///           clock skew, expiry, monotonicity (replay), the fx leg and — for new risk — the deviation bound;
///        3. only then is the price used, and only under the gates of whitepaper §4/§7.
///
///      A caller-supplied price, an exchange BBO or an unverified API response can never become a settlement price:
///      there is no code path that accepts a price without a report.
///
///      Custody: user margin sits in this contract, loss-funded pool cash sits in `HousePool`, and all venue revenue
///      sits in `BuybackVault` (2-of-2: founder + VC). They are separate ledgers and one unit of USDC is only ever
///      counted in one of them.
contract DiamondLiquid is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint16 public constant PROTOCOL_MAX_LEVERAGE = 1000;

    IERC20 public immutable usdc;
    MarketRegistry public immutable registry;
    HousePool public immutable pool;
    IReportVerifier public immutable verifier;
    LossRewardDistributor public distributor;

    /// @notice Publishes the active payout curve per market; a close uses whatever curve is published when it settles.
    address public keeper;

    /// @notice Off-chain orchestrator allowed to open positions on a user's behalf (a CRE workflow consumer, or a
    ///         plain relayer). Whitepaper §3: no off-chain component can bypass a contract check — the relayer only
    ///         supplies calldata, and the same report verification and risk gates run either way.
    address public relayer;

    /// @notice Smallest margin a position may post, USDC base units.
    uint256 public minMargin = 5e6;

    /// @notice Total open notional may not exceed `pool.availableCash() * poolCapacityMultiple`. 0 disables the check.
    /// @dev The pool launches unseeded (no LP capital): with the check enabled before any losses have accrued, every
    ///      open would revert against `0 * multiple`. Default is therefore 0 (disabled); the owner can switch it on
    ///      once the pool is loss-funded. Whitepaper §9.2.
    uint256 public poolCapacityMultiple;

    /// @notice Blocks new risk globally; existing positions can always be closed or settled.
    bool public opensPaused;

    struct Position {
        address owner;
        uint16 marketId;
        bool isLong;
        bool open;
        uint32 entryTimestamp;
        uint32 expiry;
        uint32 entryObservationsTimestamp;
        uint256 margin; // USDC base units
        uint256 notional; // margin * leverage
        uint256 entryPriceWad; // reference price at entry, WAD
        bytes32 entryReportHash; // keccak256 of the verified entry report body
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId = 1;

    /// @notice The market terms a position settled on, frozen at open.
    /// @dev A trade is a contract on the curve, the fee and the maintenance level that existed when it was opened.
    ///      Re-reading them at settlement would let an admin (or a compromised owner key) reprice a live position, so
    ///      the money-relevant terms are snapshotted here and never re-read from the registry.
    struct Terms {
        bytes32 streamId; // feed the position was opened on
        uint128 referenceNotionalWad;
        uint128 positionMultiplierWad;
        uint64 rateMultiplier;
        uint16 baseRateBps;
        uint16 winFeeBps;
        uint16 maintenanceMarginBps;
    }

    mapping(uint256 => Terms) public terms;

    /// @notice Free (unlocked) margin per account.
    mapping(address => uint256) public marginBalance;
    mapping(address => uint256) public accountOpenNotional;
    mapping(uint16 => uint256) public marketOpenNotional;
    uint256 public totalOpenNotional;

    /// @notice Last accepted reference price / report timestamp per market (deviation bound and replay guard).
    mapping(uint16 => uint256) public lastPriceWad;
    mapping(uint16 => uint32) public lastObservationsTimestamp;
    mapping(uint16 => PayoutMath.Curve) public activeCurve;

    event MarginDeposited(address indexed account, uint256 amount);
    event MarginWithdrawn(address indexed account, uint256 amount);
    event ReportAccepted(
        uint16 indexed marketId,
        bytes32 indexed streamId,
        uint32 observationsTimestamp,
        uint256 priceWad,
        bytes32 bodyHash
    );
    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        uint16 indexed marketId,
        bool isLong,
        uint256 margin,
        uint256 notional,
        uint256 entryPriceWad,
        uint32 expiry,
        bytes32 entryReportHash
    );
    event PositionClosed(
        uint256 indexed positionId,
        address indexed owner,
        uint16 indexed marketId,
        uint256 exitPriceWad,
        uint256 rawPnl,
        uint256 scaleWad,
        uint256 winFee,
        uint256 netPnl,
        uint256 paidNow,
        uint256 queued
    );
    event KeeperSet(address indexed keeper);
    event RelayerSet(address indexed relayer);
    event DistributorSet(address indexed distributor);
    event MinMarginSet(uint256 minMargin);
    event PoolCapacityMultipleSet(uint256 multiple);
    event OpensPausedSet(bool paused);
    event ActiveCurveSet(uint16 indexed marketId, PayoutMath.Curve curve);
    event PositionLossSettled(
        uint256 indexed positionId,
        address indexed owner,
        uint16 indexed marketId,
        uint256 exitPriceWad,
        uint256 loss,
        uint256 marginReturned,
        bool liquidated
    );

    error MarketDisabled();
    error MarketHalted();
    error MarketClosed();
    error OpensPaused();
    error NotPositionOwner();
    error NotKeeper();
    error NotRelayer();
    error BadAddress();
    error PositionNotOpen();
    error NotExpired();
    error NotLiquidatable();
    error BadMargin();
    error BadLeverage();
    error BadDuration();
    error ReportNotYetValid();
    error InvalidReportWindow();
    error UnsupportedSchema();
    error RegistryEngineMismatch();
    error InsufficientFreeMargin();
    error MarketCapacityExceeded();
    error AccountCapacityExceeded();
    error PoolCapacityExceeded();
    error WrongStreamId();
    error BadPrice();
    error StaleReport();
    error ReportFromFuture();
    error ExpiredReport();
    error ReplayReport();
    error DeviationExceeded();
    error UnexpectedFxReport();
    error MissingFxReport();
    error FxReportInvalid();

    constructor(
        IERC20 usdc_,
        MarketRegistry registry_,
        HousePool pool_,
        IReportVerifier verifier_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(usdc_) == address(0) || address(registry_) == address(0) || address(pool_) == address(0)
                || address(verifier_) == address(0)
        ) revert BadAddress();
        usdc = usdc_;
        registry = registry_;
        pool = pool_;
        verifier = verifier_;
    }

    // ------------------------------------------------------------------ margin

    /// @notice Deposit USDC margin. No account-activation or first-deposit fee (whitepaper §5).
    function depositMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadMargin();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        marginBalance[msg.sender] += amount;
        emit MarginDeposited(msg.sender, amount);
    }

    /// @notice Withdraw free margin. Margin backing an open position stays locked until that position settles.
    function withdrawMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadMargin();
        uint256 free = marginBalance[msg.sender];
        if (amount > free) revert InsufficientFreeMargin();
        marginBalance[msg.sender] = free - amount;
        usdc.safeTransfer(msg.sender, amount);
        emit MarginWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ trading

    /// @notice Open-request bundle. Keeps the public entry point readable and the stack shallow.
    struct OpenParams {
        uint16 marketId;
        bool isLong;
        uint256 margin; // USDC base units
        uint16 leverage;
        uint32 duration; // seconds
    }

    /// @notice Open a synthetic position against one enabled market (whitepaper §4).
    /// @param params market, direction, margin, leverage and duration
    /// @param payload full signed Data Streams report for the market's stream id
    /// @param fxPayload full signed report for the market's fx stream id, or empty when USD-quoted
    function openPosition(OpenParams calldata params, bytes calldata payload, bytes calldata fxPayload)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        positionId = _open(msg.sender, params, payload, fxPayload);
    }

    /// @notice Open a position on behalf of `account`, for the authorised relayer / CRE forwarder.
    /// @dev The position, the margin and the reward accounting all belong to `account`; the caller only supplies the
    ///      transaction. Used by `CrePositionForwarder`, which receives a CRE workflow report.
    function openPositionFor(
        address account,
        OpenParams calldata params,
        bytes calldata payload,
        bytes calldata fxPayload
    ) external nonReentrant returns (uint256 positionId) {
        if (msg.sender != relayer) revert NotRelayer();
        positionId = _open(account, params, payload, fxPayload);
    }

    function _open(address account, OpenParams calldata params, bytes calldata payload, bytes calldata fxPayload)
        internal
        returns (uint256 positionId)
    {
        if (opensPaused) revert OpensPaused();
        if (registry.engine() != address(this)) revert RegistryEngineMismatch();
        MarketRegistry.Market memory m = _tradableMarket(params.marketId);
        _checkOpenParams(account, params, m);

        (uint256 priceWad, uint32 observationsTimestamp, bytes32 bodyHash) =
            _consumeReport(params.marketId, m, bytes32(0), payload, fxPayload, true);

        positionId = _storePosition(account, params, priceWad, observationsTimestamp, bodyHash);
    }

    /// @notice Close an open position early at a fresh verified reference price.
    function closePosition(uint256 positionId, bytes calldata payload, bytes calldata fxPayload)
        external
        nonReentrant
        returns (uint256 netPnl)
    {
        Position storage p = positions[positionId];
        if (!p.open) revert PositionNotOpen();
        if (msg.sender != p.owner && msg.sender != keeper) revert NotPositionOwner();

        netPnl = _close(positionId, p, payload, fxPayload);
    }

    /// @notice Settle an expired position. Permissionless, so a matured position cannot be left dangling.
    /// @dev The settlement report must not predate the expiry.
    function settleExpired(uint256 positionId, bytes calldata payload, bytes calldata fxPayload)
        external
        nonReentrant
        returns (uint256 netPnl)
    {
        Position storage p = positions[positionId];
        if (!p.open) revert PositionNotOpen();
        if (block.timestamp < p.expiry) revert NotExpired();

        MarketRegistry.Market memory m = registry.market(p.marketId);
        (uint256 priceWad, uint32 observationsTimestamp, bytes32 bodyHash) =
            _consumeReport(p.marketId, m, terms[positionId].streamId, payload, fxPayload, false);
        if (observationsTimestamp < p.expiry) revert StaleReport();

        netPnl = _settle(positionId, p, priceWad, bodyHash, false);
    }

    /// @notice Liquidate a position whose equity has reached its maintenance margin. Permissionless.
    /// @dev No separate percentage surcharge: the trader keeps whatever margin survives the loss (whitepaper §5).
    function liquidate(uint256 positionId, bytes calldata payload, bytes calldata fxPayload)
        external
        nonReentrant
        returns (uint256 loss)
    {
        Position storage p = positions[positionId];
        if (!p.open) revert PositionNotOpen();

        MarketRegistry.Market memory m = registry.market(p.marketId);
        (uint256 priceWad,, bytes32 bodyHash) =
            _consumeReport(p.marketId, m, terms[positionId].streamId, payload, fxPayload, false);

        if (!_isLiquidatable(positionId, p, priceWad)) revert NotLiquidatable();

        // Report the realised loss for observers; `_settle` books the cash and the reward accounting.
        loss = PayoutMath.loss(p.notional, PayoutMath.adverseMoveWad(p.entryPriceWad, priceWad, p.isLong));
        if (loss > p.margin) loss = p.margin;
        _settle(positionId, p, priceWad, bodyHash, true);
    }

    // ------------------------------------------------------------------ open helpers

    function _checkOpenParams(address account, OpenParams calldata params, MarketRegistry.Market memory m)
        internal
        view
    {
        if (params.margin < minMargin) revert BadMargin();
        if (params.leverage == 0 || params.leverage > m.maxLeverage || params.leverage < m.minLeverage) {
            revert BadLeverage();
        }
        if (params.duration < m.minDuration || params.duration > m.maxDuration) revert BadDuration();
        if (params.margin > marginBalance[account]) revert InsufficientFreeMargin();

        uint256 notional = params.margin * uint256(params.leverage);
        if (marketOpenNotional[params.marketId] + notional > m.maxOpenNotional) revert MarketCapacityExceeded();
        if (accountOpenNotional[account] + notional > m.maxAccountNotional) revert AccountCapacityExceeded();

        uint256 multiple = poolCapacityMultiple;
        if (multiple != 0 && totalOpenNotional + notional > pool.availableCash() * multiple) {
            revert PoolCapacityExceeded();
        }
    }

    function _storePosition(
        address account,
        OpenParams calldata params,
        uint256 priceWad,
        uint32 observationsTimestamp,
        bytes32 bodyHash
    ) internal returns (uint256 positionId) {
        uint256 notional = params.margin * uint256(params.leverage);
        marginBalance[account] -= params.margin;
        accountOpenNotional[account] += notional;
        marketOpenNotional[params.marketId] += notional;
        totalOpenNotional += notional;

        positionId = nextPositionId++;
        uint32 expiry = uint32(block.timestamp) + params.duration;

        {
            MarketRegistry.Market memory m = registry.market(params.marketId);
            terms[positionId] = Terms({
                streamId: m.streamId,
                referenceNotionalWad: m.referenceNotionalWad,
                positionMultiplierWad: m.positionMultiplierWad,
                rateMultiplier: m.rateMultiplier,
                baseRateBps: m.baseRateBps,
                winFeeBps: m.winFeeBps,
                maintenanceMarginBps: m.maintenanceMarginBps
            });
        }
        positions[positionId] = Position({
            owner: account,
            marketId: params.marketId,
            isLong: params.isLong,
            open: true,
            entryTimestamp: uint32(block.timestamp),
            expiry: expiry,
            entryObservationsTimestamp: observationsTimestamp,
            margin: params.margin,
            notional: notional,
            entryPriceWad: priceWad,
            entryReportHash: bodyHash
        });

        LossRewardDistributor d = distributor;
        if (address(d) != address(0)) {
            d.recordOpen(params.marketId, params.isLong, notional);
        }

        emit PositionOpened(
            positionId, account, params.marketId, params.isLong, params.margin, notional, priceWad, expiry, bodyHash
        );
    }

    // ------------------------------------------------------------------ views

    /// @notice Unrealised PnL at `priceWad`, gross of every winning-close adjustment.
    function unrealizedPnl(uint256 positionId, uint256 priceWad) public view returns (int256) {
        return _unrealizedPnl(positions[positionId], priceWad);
    }

    /// @notice Position equity = margin + unrealised PnL, floored at zero (whitepaper §5).
    function positionEquity(uint256 positionId, uint256 priceWad) public view returns (uint256 equity) {
        int256 value = int256(positions[positionId].margin) + _unrealizedPnl(positions[positionId], priceWad);
        equity = value > 0 ? uint256(value) : 0;
    }

    /// @notice Maintenance margin required for a position, in USDC base units.
    /// @dev Uses the position's frozen maintenance level, not the market's current one.
    function maintenanceMargin(uint256 positionId) public view returns (uint256) {
        Position storage p = positions[positionId];
        return p.notional * terms[positionId].maintenanceMarginBps / BPS;
    }

    /// @notice Whether a position can be liquidated at `priceWad`.
    function isLiquidatable(uint256 positionId, uint256 priceWad) public view returns (bool) {
        return _isLiquidatable(positionId, positions[positionId], priceWad);
    }

    /// @notice Everything a UI needs to show a market honestly. Prices and pool cash are shown separately (§7).
    struct MarketSnapshot {
        bool enabled;
        bool halted;
        bool sessionOpen;
        uint256 referencePriceWad;
        uint32 priceTimestamp;
        uint256 openNotional;
        uint256 maxOpenNotional;
        uint16 maxLeverage;
        PayoutMath.Curve curve;
        uint256 houseCash;
        uint256 queuedClaims;
    }

    function marketSnapshot(uint16 marketId) external view returns (MarketSnapshot memory s) {
        MarketRegistry.Market memory m = registry.market(marketId);
        s = MarketSnapshot({
            enabled: m.enabled,
            halted: m.halted,
            sessionOpen: registry.isOpenAt(marketId, block.timestamp),
            referencePriceWad: lastPriceWad[marketId],
            priceTimestamp: lastObservationsTimestamp[marketId],
            openNotional: marketOpenNotional[marketId],
            maxOpenNotional: m.maxOpenNotional,
            maxLeverage: m.maxLeverage,
            curve: activeCurve[marketId],
            houseCash: pool.availableCash(),
            queuedClaims: pool.queuedClaims()
        });
    }

    /// @notice Preview a winning close without touching state. Mirrors the on-chain pipeline exactly.
    function previewWin(uint256 positionId, uint256 priceWad) external view returns (PayoutMath.WinResult memory) {
        Position storage p = positions[positionId];
        uint256 move = PayoutMath.favourableMoveWad(p.entryPriceWad, priceWad, p.isLong);
        return PayoutMath.win(p.notional, move, _calibration(positionId), activeCurve[p.marketId]);
    }

    // ------------------------------------------------------------------ settlement internals

    function _close(uint256 positionId, Position storage p, bytes calldata payload, bytes calldata fxPayload)
        internal
        returns (uint256 netPnl)
    {
        MarketRegistry.Market memory m = registry.market(p.marketId);
        (uint256 priceWad,, bytes32 bodyHash) =
            _consumeReport(p.marketId, m, terms[positionId].streamId, payload, fxPayload, false);
        return _settle(positionId, p, priceWad, bodyHash, false);
    }

    /// @dev Applies the §5 pipeline, moves cash between margin, pool and trader, and books reward accounting.
    function _settle(uint256 positionId, Position storage p, uint256 exitPriceWad, bytes32 bodyHash, bool liquidation)
        internal
        returns (uint256 netPnl)
    {
        // A position may never be settled with the very report that opened it.
        if (bodyHash != bytes32(0) && bodyHash == p.entryReportHash) revert ReplayReport();

        bool favourable = (p.isLong && exitPriceWad > p.entryPriceWad) || (!p.isLong && exitPriceWad < p.entryPriceWad);
        uint32 held = uint32(block.timestamp) - p.entryTimestamp;

        _closeBooks(p);

        if (favourable) {
            netPnl = _settleWin(positionId, p, exitPriceWad);
        } else {
            _settleLoss(positionId, p, exitPriceWad, held, liquidation);
        }
    }

    function _closeBooks(Position storage p) internal {
        uint256 notional = p.notional;
        address owner_ = p.owner;
        uint16 marketId = p.marketId;

        p.open = false;
        accountOpenNotional[owner_] -= notional;
        marketOpenNotional[marketId] -= notional;
        totalOpenNotional -= notional;
    }

    /// @dev Winning close: deadband -> holdback -> impact haircut -> 1.99% win fee -> payout or FIFO claim.
    function _settleWin(uint256 positionId, Position storage p, uint256 exitPriceWad)
        internal
        returns (uint256 netPnl)
    {
        uint256 move = PayoutMath.favourableMoveWad(p.entryPriceWad, exitPriceWad, p.isLong);
        PayoutMath.WinResult memory r =
            PayoutMath.win(p.notional, move, _calibration(positionId), activeCurve[p.marketId]);

        // Locked margin is released back to free margin; profit comes from pool cash.
        marginBalance[p.owner] += p.margin;

        uint256 paid = 0;
        uint256 queued = 0;
        if (r.netPnl != 0) {
            uint256 impactRetained = r.rawPnl > r.adjustedPnl ? r.rawPnl - r.adjustedPnl : 0;
            (paid, queued) = pool.settleProfit(p.owner, r.netPnl, r.winFee, impactRetained);
        }

        emit PositionClosed(
            positionId, p.owner, p.marketId, exitPriceWad, r.rawPnl, r.scaleWad, r.winFee, r.netPnl, paid, queued
        );

        netPnl = r.netPnl;
    }

    /// @dev Losing close: no percentage fee, no win fee, no reward mint. Loss is capped at the posted margin.
    function _settleLoss(uint256 positionId, Position storage p, uint256 exitPriceWad, uint32 held, bool liquidation)
        internal
    {
        uint256 margin = p.margin;
        uint256 lossUsd =
            PayoutMath.loss(p.notional, PayoutMath.adverseMoveWad(p.entryPriceWad, exitPriceWad, p.isLong));
        if (lossUsd > margin) lossUsd = margin;

        uint256 remaining = margin - lossUsd;
        if (remaining != 0) marginBalance[p.owner] += remaining;

        if (lossUsd != 0) {
            usdc.safeTransfer(address(pool), lossUsd);
            pool.receiveLoss(lossUsd);

            LossRewardDistributor d = distributor;
            if (address(d) != address(0)) {
                d.recordSettledLoss(p.owner, p.marketId, lossUsd, held, p.entryTimestamp);
            }
        }

        emit PositionLossSettled(positionId, p.owner, p.marketId, exitPriceWad, lossUsd, remaining, liquidation);
    }

    // ------------------------------------------------------------------ report handling

    /// @dev Verify, validate, record — and for new risk apply the deviation bound against the *previous accepted* price.
    /// @param gateDeviation true for anything that increases risk; false for closes, settlements and liquidations so a
    ///        crash or a gap can never trap an existing position (whitepaper §7).
    function _consumeReport(
        uint16 marketId,
        MarketRegistry.Market memory m,
        bytes32 expectedStreamId,
        bytes calldata payload,
        bytes calldata fxPayload,
        bool gateDeviation
    ) internal returns (uint256 priceWad, uint32 observationsTimestamp, bytes32 bodyHash) {
        uint256 previous = lastPriceWad[marketId];
        (priceWad, observationsTimestamp, bodyHash) =
            _validateReport(marketId, m, expectedStreamId, payload, fxPayload);

        if (gateDeviation && previous != 0) {
            uint256 diff = priceWad > previous ? priceWad - previous : previous - priceWad;
            if (diff * BPS > previous * m.maxDeviationBps) revert DeviationExceeded();
        }

        lastPriceWad[marketId] = priceWad;
        lastObservationsTimestamp[marketId] = observationsTimestamp;
        emit ReportAccepted(marketId, m.streamId, observationsTimestamp, priceWad, bodyHash);
    }

    /// @dev The application-level gate a DON signature alone does not provide (whitepaper §3).
    function _validateReport(
        uint16 marketId,
        MarketRegistry.Market memory m,
        bytes32 expectedStreamId,
        bytes calldata payload,
        bytes calldata fxPayload
    ) internal returns (uint256 priceWad, uint32 observationsTimestamp, bytes32 bodyHash) {
        if (!m.enabled) revert MarketDisabled();
        // Only the two reviewed body shapes are decodable. A market whose feed carries a status word (or any future
        // schema) cannot be traded when correctly declared. Feed schema and identity must still be verified off chain.
        if (m.schema > 1 || m.statusScheme != 0) revert UnsupportedSchema();

        bytes32 expectedStream = expectedStreamId == bytes32(0) ? m.streamId : expectedStreamId;

        bytes memory body = verifier.verify(payload);
        bodyHash = ReportLib.bodyHash(body);
        ReportLib.Report memory report =
            m.schema == 0 ? ReportLib.decodeSingle(body) : ReportLib.decodeBundleAt(body, m.bundleIndex);

        if (report.feedId != expectedStream) revert WrongStreamId();
        if (report.price <= 0) revert BadPrice();
        // A two-sided quote must be two-sided: a payload whose bid decoded but whose ask did not (or vice versa) is a
        // schema mismatch, not a thin book.
        if ((report.bid > 0) != (report.ask > 0)) revert BadPrice();
        if (report.bid > 0 && report.bid > report.ask) revert BadPrice();

        priceWad = _toWad(uint256(int256(report.price)), m.priceDecimals);
        if (priceWad == 0) revert BadPrice();

        observationsTimestamp = report.observationsTimestamp;
        // The report's validity window is part of the report, not an inference from the clock (Chainlink §Data
        // Streams): a report may not be used before `validFromTimestamp`, and a window that runs backwards is invalid.
        if (report.validFromTimestamp > observationsTimestamp) revert InvalidReportWindow();
        if (observationsTimestamp > block.timestamp + m.maxFutureSkewSeconds) revert ReportFromFuture();
        if (block.timestamp > uint256(observationsTimestamp) + m.maxAgeSeconds) revert StaleReport();
        // A report that is inside the freshness window but whose own validity window has not opened yet is still
        // unusable: `validFromTimestamp` is the start of the window the DON signed, not a hint.
        if (report.validFromTimestamp > block.timestamp) revert ReportNotYetValid();
        if (report.expiresAt != 0 && block.timestamp > report.expiresAt) revert ExpiredReport();
        // Replay: a report older than one already accepted for this market can never price another action.
        if (observationsTimestamp < lastObservationsTimestamp[marketId]) revert ReplayReport();

        if (m.fxStreamId != bytes32(0)) {
            if (fxPayload.length == 0) revert MissingFxReport();
            priceWad = priceWad * _fxRate(m.fxStreamId, fxPayload) / WAD;
            if (priceWad == 0) revert BadPrice();
        } else if (fxPayload.length != 0) {
            revert UnexpectedFxReport();
        }
    }

    /// @dev Explicit, verified conversion leg for non-USD quotations. v1 accepts 18-decimal single-schema FX reports;
    ///      a market whose quote needs anything else stays disabled until its decoder is reviewed.
    function _fxRate(bytes32 fxStreamId, bytes calldata fxPayload) internal returns (uint256 rateWad) {
        bytes memory body = verifier.verify(fxPayload);
        ReportLib.Report memory report = ReportLib.decodeSingle(body);
        if (report.feedId != fxStreamId) revert FxReportInvalid();
        if (report.price <= 0) revert FxReportInvalid();
        if (report.validFromTimestamp > report.observationsTimestamp) revert FxReportInvalid();
        if (report.validFromTimestamp > block.timestamp) revert FxReportInvalid();
        if (report.expiresAt != 0 && block.timestamp > report.expiresAt) revert FxReportInvalid();
        if (report.observationsTimestamp > block.timestamp + 120) revert FxReportInvalid();
        if (block.timestamp > uint256(report.observationsTimestamp) + 300) revert FxReportInvalid();
        rateWad = _toWad(uint256(int256(report.price)), 18);
    }

    function _toWad(uint256 price, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) return price;
        if (decimals_ < 18) return price * 10 ** (18 - uint256(decimals_));
        return price / 10 ** (uint256(decimals_) - 18);
    }

    /// @dev The payout terms the position was opened on. Never the market's current terms.
    function _calibration(uint256 positionId) internal view returns (PayoutMath.Calibration memory) {
        Terms storage t = terms[positionId];
        return PayoutMath.Calibration({
            referenceNotionalWad: t.referenceNotionalWad,
            rateMultiplier: t.rateMultiplier,
            positionMultiplierWad: t.positionMultiplierWad,
            baseRateBps: t.baseRateBps,
            winFeeBps: t.winFeeBps
        });
    }

    function _tradableMarket(uint16 marketId) internal view returns (MarketRegistry.Market memory m) {
        m = registry.market(marketId);
        if (!m.enabled) revert MarketDisabled();
        if (m.halted) revert MarketHalted();
        if (!registry.isOpenAt(marketId, block.timestamp)) revert MarketClosed();
    }

    function _unrealizedPnl(Position storage p, uint256 priceWad) internal view returns (int256) {
        if (!p.open || priceWad == 0) return 0;
        if ((p.isLong && priceWad > p.entryPriceWad) || (!p.isLong && priceWad < p.entryPriceWad)) {
            return
                int256(PayoutMath.loss(p.notional, PayoutMath.favourableMoveWad(p.entryPriceWad, priceWad, p.isLong)));
        }
        return -int256(PayoutMath.loss(p.notional, PayoutMath.adverseMoveWad(p.entryPriceWad, priceWad, p.isLong)));
    }

    function _isLiquidatable(uint256 positionId, Position storage p, uint256 priceWad) internal view returns (bool) {
        int256 value = int256(p.margin) + _unrealizedPnl(p, priceWad);
        uint256 equity = value > 0 ? uint256(value) : 0;
        return equity <= p.notional * terms[positionId].maintenanceMarginBps / BPS;
    }

    // ------------------------------------------------------------------ admin

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert BadAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Authorise the relayer / CRE forwarder that may call `openPositionFor`.
    function setRelayer(address relayer_) external onlyOwner {
        if (relayer_ == address(0)) revert BadAddress();
        relayer = relayer_;
        emit RelayerSet(relayer_);
    }

    function setDistributor(LossRewardDistributor distributor_) external onlyOwner {
        if (address(distributor_) == address(0)) revert BadAddress();
        distributor = distributor_;
        emit DistributorSet(address(distributor_));
    }

    function setMinMargin(uint256 minMargin_) external onlyOwner {
        minMargin = minMargin_;
        emit MinMarginSet(minMargin_);
    }

    function setPoolCapacityMultiple(uint256 multiple) external onlyOwner {
        poolCapacityMultiple = multiple;
        emit PoolCapacityMultipleSet(multiple);
    }

    function setOpensPaused(bool paused) external onlyOwner {
        opensPaused = paused;
        emit OpensPausedSet(paused);
    }

    /// @notice Publish the payout curve the next closes on this market will use.
    function setActiveCurve(uint16 marketId, PayoutMath.Curve curve) external {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        activeCurve[marketId] = curve;
        emit ActiveCurveSet(marketId, curve);
    }
}
