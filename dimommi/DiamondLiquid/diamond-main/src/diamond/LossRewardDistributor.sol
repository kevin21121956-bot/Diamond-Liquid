// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILossRewardDistributor} from "./interfaces/ILossRewardDistributor.sol";

/// @title LossRewardDistributor
/// @notice Phase 1 / Phase 2 settled-loss rewards of whitepaper §6.
/// @dev Rewards are a release of *pre-issued* DIAMOND. This contract never mints; it holds the 50,000,000 Phase 1
///      reserve in a segregated vault balance (`reserveRemaining`) and, in Phase 2, the inventory actually bought back
///      (`buybackInventory`).
///
///      Per epoch (one hour):
///        HedgeRatio(a,e)  = min(1, |sum LONG - sum SHORT| / gross open notional of a in e)
///        EligibleLoss(i,e)= sum over assets of LossBasis(i,a,e) * HedgeRatio(a,e)
///        RawReward(i,e)   = EligibleLoss(i,e) * BaseRate      (BaseRate = 1.0 DIAMOND per USDC)
///        EpochBudget(e)   = r(e) * RealRevenue(e)             (capped by available inventory)
///        ReserveScale(e)  = min(1, EpochBudget / sum RawReward)
///        Reward(i,e)      = RawReward * ReserveScale          (then the cluster cap)
///        ClusterCap(e)    = 2% of EpochBudget per linked-wallet cluster
///
///      25% of a finalized award is claimable immediately, 75% vests linearly over 180 days. The whole commitment,
///      vested or not, is deducted from inventory at finalization.
contract LossRewardDistributor is Ownable, ReentrancyGuard, ILossRewardDistributor {
    using SafeERC20 for IERC20;
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    uint256 public constant EPOCH = 1 hours;
    uint256 public constant VEST_DURATION = 180 days;
    uint256 public constant IMMEDIATE_BPS = 2_500; // 25% claimable at once
    uint256 public constant CLUSTER_CAP_BPS = 200; // 2% of the epoch budget per cluster
    uint256 public constant MIN_HOLD_SECONDS = 60;
    uint256 public constant BASE_RATE = 1e18; // 1.0 DIAMOND per USDC of eligible loss (nominal, not a floor)
    /// @notice Floor-division dust allowed to remain in the Phase 1 reserve when Phase 2 is activated.
    /// @dev Each committed reward loses < 1 wei (RawReward * scale / WAD), so the residue after the last distributable
    ///      wei is permanently locked. 1e12 wei == 1e-6 DIAMOND: economically zero, and small enough that no real
    ///      reserve balance can ever be swept past this bound.
    uint256 public constant PHASE2_DUST = 1e12;

    IERC20 public immutable diamond;
    address public engine;
    /// @notice The House Pool, the only other contract allowed to report collected cash.
    address public revenueSource;

    /// @notice Published token-budget coefficient r(e), in DIAMOND per USDC of real revenue. Set after scenario testing.
    uint256 public budgetCoefficient;
    /// @notice Number of roster rows to scan when computing hedge ratios (the 26 markets of whitepaper §2).
    uint16 public marketCount;

    /// @notice The 2-of-2 BuybackVault allowed to credit executed-swap DIAMOND as Phase 2 inventory.
    address public buybackVault;

    uint256 public reserveRemaining; // Phase 1: pre-issued reserve still uncommitted
    uint256 public buybackInventory; // Phase 2: DIAMOND actually received from executed buybacks
    uint256 public totalCommitted;
    uint256 public totalClaimed;
    bool public phase2;

    struct Epoch {
        uint256 revenue; // USDC base units actually collected into the buyback bucket
        uint256 budget; // token budget for the epoch
        uint256 totalRaw; // sum of raw rewards
        uint256 scale; // reserve scale, WAD
        uint256 committed; // tokens committed
        bool finalized;
    }

    struct Award {
        uint128 immediate;
        uint128 vesting;
        uint64 start;
        uint128 claimed;
    }

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(uint16 => uint256)) public marketGrossNotional;
    mapping(uint256 => mapping(uint16 => int256)) public marketNetFlow;
    // Only one epoch may finalize at a time: otherwise separate epochs could snapshot and spend the same inventory.
    uint256 public activeEpochPlusOne;
    struct Finalization { uint8 phase; uint256 walletCursor; uint256 cohortCursor; uint256 startedAt; }
    mapping(uint256 => Finalization) public finalization;
    mapping(uint256 => mapping(address => uint256)) private _rawByWallet;
    mapping(uint256 => mapping(bytes32 => uint256)) private _clusterCommitted;

    mapping(uint256 => mapping(address => mapping(uint16 => uint256))) private _lossBasis;
    // A closing epoch may contain positions opened in several epochs. Preserve each opening cohort until
    // finalization, when the complete entry-epoch flow is known.
    struct LossCohort { uint256 entryEpoch; uint16 marketId; uint256 loss; }
    mapping(uint256 => mapping(address => LossCohort[])) private _lossCohorts;
    mapping(uint256 => mapping(address => mapping(uint256 => mapping(uint16 => uint256)))) private _cohortIndex;
    mapping(uint256 => address[]) private _epochWallets;
    mapping(uint256 => mapping(address => bool)) private _tracked;
    mapping(address => bytes32) public clusterOf;
    mapping(address => Award[]) private _awards;

    event EngineSet(address indexed engine);
    event BuybackVaultSet(address indexed vault);
    event RevenueRecorded(uint256 indexed epoch, uint256 winFeeCash, uint256 lossBuybackCash, uint256 epochRevenue);
    event FlowRecorded(uint256 indexed epoch, uint16 indexed market, bool isLong, uint256 notional);
    event LossRecorded(uint256 indexed epoch, address indexed wallet, uint16 indexed market, uint256 loss, uint32 held);
    event LossCohortRecorded(uint256 indexed closingEpoch, address indexed wallet, uint16 indexed market, uint256 entryEpoch, uint256 loss);
    event EpochFinalized(
        uint256 indexed epoch, uint256 revenue, uint256 budget, uint256 totalRaw, uint256 scale, uint256 committed
    );
    event RewardCommitted(uint256 indexed epoch, address indexed wallet, uint256 reward, uint256 immediate);
    event RewardClaimed(address indexed wallet, uint256 amount);
    event Phase2Activated(uint256 inventory);
    event BuybackInventoryAdded(uint256 amount, uint256 inventory);
    event ClusterSet(address indexed wallet, bytes32 cluster);
    event BudgetCoefficientSet(uint256 coefficientWad);
    event MarketCountSet(uint16 count);
    event RevenueSourceSet(address indexed source);
    event ReserveSeeded(address indexed from, uint256 amount, uint256 reserveRemaining);

    error NotEngine();
    error EpochNotFinished();
    error AlreadyFinalized();
    error NothingToClaim();
    error FinalizationActive();
    error WrongFinalizationPhase();
    error FinalizationIncomplete();
    error EmptyBatch();
    error ReserveNotEmpty();
    error ZeroAmount();
    error NotAuthorised();

    constructor(IERC20 diamond_, address initialOwner) Ownable(initialOwner) {
        diamond = diamond_;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    // ------------------------------------------------------------------ views

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    function claimable(address wallet) public view returns (uint256 amount) {
        Award[] storage list = _awards[wallet];
        for (uint256 i = 0; i < list.length; ++i) {
            amount += _claimable(list[i]);
        }
    }

    function awardCount(address wallet) external view returns (uint256) {
        return _awards[wallet].length;
    }

    function awardAt(address wallet, uint256 index) external view returns (Award memory) {
        return _awards[wallet][index];
    }

    function hedgeRatio(uint256 epochId, uint16 marketId) public view returns (uint256) {
        uint256 gross = marketGrossNotional[epochId][marketId];
        if (gross == 0) return 0;
        int256 net = marketNetFlow[epochId][marketId];
        uint256 absNet = net >= 0 ? uint256(net) : uint256(-net);
        if (absNet >= gross) return WAD;
        return absNet * WAD / gross;
    }

    function lossBasis(uint256 epochId, address wallet, uint16 marketId) external view returns (uint256) {
        return _lossBasis[epochId][wallet][marketId];
    }

    function epochWalletCount(uint256 epochId) external view returns (uint256) {
        return _epochWallets[epochId].length;
    }

    // ------------------------------------------------------------------ engine hooks

    function recordRevenue(uint256 winFeeCash, uint256 lossBuybackCash) external override {
        if (msg.sender != revenueSource) revert NotEngine();
        _recordRevenue(winFeeCash, lossBuybackCash);
    }

    /// @notice Record gross long/short notional opened on a market during the current epoch.
    function recordOpen(uint16 marketId, bool isLong, uint256 notional) external onlyEngine {
        uint256 epochId = currentEpoch();
        marketGrossNotional[epochId][marketId] += notional;
        marketNetFlow[epochId][marketId] += isLong ? int256(notional) : -int256(notional);
        emit FlowRecorded(epochId, marketId, isLong, notional);
    }

    /// @notice Record a settled loss for reward eligibility.
    /// @dev Open or unrealised PnL never qualifies, and a position closed before MinHoldTime contributes zero
    ///      reward-eligible loss without changing its cash PnL accounting (whitepaper §6).
    function recordSettledLoss(address wallet, uint16 marketId, uint256 lossUsd, uint32 heldSeconds, uint32 entryTimestamp)
        external
        onlyEngine
    {
        if (lossUsd == 0 || heldSeconds < MIN_HOLD_SECONDS) return;
        uint256 epochId = currentEpoch();
        _lossBasis[epochId][wallet][marketId] += lossUsd;
        uint256 entryEpoch = uint256(entryTimestamp) / EPOCH;
        require(entryEpoch <= epochId, "future entry");
        uint256 index = _cohortIndex[epochId][wallet][entryEpoch][marketId];
        if (index == 0) {
            _lossCohorts[epochId][wallet].push(LossCohort(entryEpoch, marketId, lossUsd));
            _cohortIndex[epochId][wallet][entryEpoch][marketId] = _lossCohorts[epochId][wallet].length;
        } else {
            _lossCohorts[epochId][wallet][index - 1].loss += lossUsd;
        }
        if (!_tracked[epochId][wallet]) {
            _tracked[epochId][wallet] = true;
            _epochWallets[epochId].push(wallet);
        }
        emit LossRecorded(epochId, wallet, marketId, lossUsd, heldSeconds);
        emit LossCohortRecorded(epochId, wallet, marketId, entryEpoch, lossUsd);
    }

    // ------------------------------------------------------------------ epochs

    /// @notice Convenience wrapper for small epochs. Large epochs use the permissionless bounded functions below.
    function finalizeEpoch(uint256 epochId) external returns (uint256 committed) {
        _beginFinalize(epochId);
        _accrue(epochId, type(uint256).max);
        _commit(epochId, type(uint256).max);
        _finish(epochId);
        return epochs[epochId].committed;
    }

    function beginFinalize(uint256 epochId) external { _beginFinalize(epochId); }
    function accrueRewards(uint256 epochId, uint256 maxItems) external { _accrue(epochId, maxItems); }
    function commitRewards(uint256 epochId, uint256 maxWallets) external { _commit(epochId, maxWallets); }
    function finishFinalize(uint256 epochId) external { _finish(epochId); }

    function _beginFinalize(uint256 epochId) internal {
        if (epochId >= currentEpoch()) revert EpochNotFinished();
        if (activeEpochPlusOne != 0) revert FinalizationActive();
        Epoch storage e = epochs[epochId];
        if (e.finalized) revert AlreadyFinalized();
        activeEpochPlusOne = epochId + 1;
        e.budget = _epochBudget(e.revenue);
        finalization[epochId] = Finalization(1, 0, 0, block.timestamp);
    }

    // Every iteration consumes at most one cohort or advances one wallet, even for a wallet with many cohorts.
    function _accrue(uint256 epochId, uint256 maxItems) internal {
        if (maxItems == 0) revert EmptyBatch();
        Finalization storage f = finalization[epochId];
        if (f.phase != 1 || activeEpochPlusOne != epochId + 1) revert WrongFinalizationPhase();
        Epoch storage e = epochs[epochId];
        address[] storage wallets = _epochWallets[epochId];
        uint256 used;
        while (f.walletCursor < wallets.length && used < maxItems) {
            address w = wallets[f.walletCursor];
            LossCohort[] storage cohorts = _lossCohorts[epochId][w];
            if (f.cohortCursor < cohorts.length) {
                LossCohort storage c = cohorts[f.cohortCursor++];
                if (c.marketId < marketCount) {
                    uint256 raw = c.loss * 1e12 * hedgeRatio(c.entryEpoch, c.marketId) / WAD * BASE_RATE / WAD;
                    _rawByWallet[epochId][w] += raw;
                    e.totalRaw += raw;
                }
            } else {
                ++f.walletCursor;
                f.cohortCursor = 0;
            }
            ++used;
        }
        if (f.walletCursor == wallets.length) {
            uint256 totalRaw = e.totalRaw;
            e.scale = (totalRaw == 0 || e.budget == 0) ? 0 :
                (e.budget >= totalRaw ? WAD : e.budget * WAD / totalRaw);
            f.phase = 2;
            f.walletCursor = 0;
        }
    }

    function _commit(uint256 epochId, uint256 maxWallets) internal {
        if (maxWallets == 0) revert EmptyBatch();
        Finalization storage f = finalization[epochId];
        if (f.phase != 2 || activeEpochPlusOne != epochId + 1) revert WrongFinalizationPhase();
        Epoch storage e = epochs[epochId];
        address[] storage wallets = _epochWallets[epochId];
        uint256 used;
        while (f.walletCursor < wallets.length && used < maxWallets) {
            address w = wallets[f.walletCursor++];
            uint256 reward = _rawByWallet[epochId][w] * e.scale / WAD;
            bytes32 cluster = clusterOf[w];
            uint256 cap = e.budget * CLUSTER_CAP_BPS / BPS;
            if (cluster != bytes32(0) && cap != 0) {
                uint256 spent = _clusterCommitted[epochId][cluster];
                uint256 room = spent >= cap ? 0 : cap - spent;
                if (reward > room) reward = room;
                _clusterCommitted[epochId][cluster] = spent + reward;
            }
            if (reward != 0) {
                uint256 immediate = reward * IMMEDIATE_BPS / BPS;
                _awards[w].push(Award(uint128(immediate), uint128(reward - immediate), uint64(f.startedAt), 0));
                e.committed += reward;
                if (phase2) buybackInventory -= reward; else reserveRemaining -= reward;
                totalCommitted += reward;
                emit RewardCommitted(epochId, w, reward, immediate);
            }
            ++used;
        }
    }

    function _finish(uint256 epochId) internal {
        Finalization storage f = finalization[epochId];
        if (f.phase != 2 || activeEpochPlusOne != epochId + 1) revert WrongFinalizationPhase();
        if (f.walletCursor != _epochWallets[epochId].length) revert FinalizationIncomplete();
        Epoch storage e = epochs[epochId];
        e.finalized = true;
        f.phase = 3;
        activeEpochPlusOne = 0;
        emit EpochFinalized(epochId, e.revenue, e.budget, e.totalRaw, e.scale, e.committed);
    }

    /// @notice Claim all currently claimable DIAMOND.
    function claim() external nonReentrant returns (uint256 amount) {
        Award[] storage list = _awards[msg.sender];
        for (uint256 i = 0; i < list.length; ++i) {
            uint256 due = _claimable(list[i]);
            if (due == 0) continue;
            list[i].claimed = uint128(uint256(list[i].claimed) + due);
            amount += due;
        }
        if (amount == 0) revert NothingToClaim();
        totalClaimed += amount;
        diamond.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------ admin

    function setEngine(address engine_) external onlyOwner {
        if (engine_ == address(0)) revert ZeroAmount();
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Point at the House Pool that reports collected cash into epochs.
    function setRevenueSource(address source_) external onlyOwner {
        if (source_ == address(0)) revert ZeroAmount();
        revenueSource = source_;
        emit RevenueSourceSet(source_);
    }

    /// @notice r(e), published before the epoch it applies to. The numerical value is a deployment decision.
    function setBudgetCoefficient(uint256 coefficientWad) external onlyOwner {
        budgetCoefficient = coefficientWad;
        emit BudgetCoefficientSet(coefficientWad);
    }

    function setMarketCount(uint16 count) external onlyOwner {
        if (activeEpochPlusOne != 0) revert FinalizationActive();
        marketCount = count;
        emit MarketCountSet(count);
    }

    /// @notice Owner-curated linked-wallet clusters. A shared funding source is a signal, not proof of ownership.
    function setCluster(address wallet, bytes32 cluster) external onlyOwner {
        if (activeEpochPlusOne != 0) revert FinalizationActive();
        clusterOf[wallet] = cluster;
        emit ClusterSet(wallet, cluster);
    }

    /// @notice Seed the Phase 1 reserve (the 50,000,000 pre-issued tokens).
    function seedReserve(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        diamond.safeTransferFrom(msg.sender, address(this), amount);
        reserveRemaining += amount;
        emit ReserveSeeded(msg.sender, amount, reserveRemaining);
    }

    /// @notice Switch to Phase 2 once the initial reserve is exhausted.
    /// @dev "Exhausted" allows up to PHASE2_DUST wei of floor-division dust to remain; that residue stays locked
    ///      forever (it is never paid out and never counted as inventory), which is the only way the zero-remainder
    ///      requirement can be met once awards have been scaled by floor division.
    function activatePhase2() external onlyOwner {
        if (activeEpochPlusOne != 0) revert FinalizationActive();
        if (reserveRemaining > PHASE2_DUST) revert ReserveNotEmpty();
        phase2 = true;
        emit Phase2Activated(buybackInventory);
    }

    /// @notice Wire the buyback vault (2-of-2) once, right after deployment. There is no path to re-point it.
    function setBuybackVault(address vault_) external onlyOwner {
        if (buybackVault != address(0)) revert NotAuthorised();
        if (vault_ == address(0)) revert ZeroAmount();
        buybackVault = vault_;
        emit BuybackVaultSet(vault_);
    }

    /// @notice Credit DIAMOND actually received from an executed buyback and move the tokens into the vault.
    /// @dev Quotes, unexecuted cash and slippage-adjusted expectations are not inventory: only tokens received.
    ///      Callable by the owner (bootstrap path) or by the 2-of-2 buyback vault after an executed swap.
    function addBuybackInventory(uint256 amount) external {
        if (msg.sender != owner() && msg.sender != buybackVault) revert NotAuthorised();
        if (amount == 0) revert ZeroAmount();
        buybackInventory += amount;
        diamond.safeTransferFrom(msg.sender, address(this), amount);
        emit BuybackInventoryAdded(amount, buybackInventory);
    }

    // ------------------------------------------------------------------ epoch internals

    /// @dev EpochBudget(e) = r(e) * RealRevenue(e), capped by available inventory (whitepaper §6).
    function _epochBudget(uint256 revenueUsdc) internal view returns (uint256) {
        uint256 revenueWad = revenueUsdc * 1e12;
        uint256 budget = budgetCoefficient * revenueWad / WAD;
        uint256 inventory = phase2 ? buybackInventory : reserveRemaining;
        return budget > inventory ? inventory : budget;
    }

    // ------------------------------------------------------------------ internal

    function _recordRevenue(uint256 winFeeCash, uint256 lossBuybackCash) internal {
        uint256 epochId = currentEpoch();
        uint256 total = winFeeCash + lossBuybackCash;
        if (total == 0) return;
        epochs[epochId].revenue += total;
        emit RevenueRecorded(epochId, winFeeCash, lossBuybackCash, epochs[epochId].revenue);
    }

    function _claimable(Award storage a) internal view returns (uint256) {
        uint256 vestedAmount = a.vesting;
        if (vestedAmount != 0) {
            uint256 elapsed = block.timestamp - a.start;
            if (elapsed < VEST_DURATION) {
                vestedAmount = uint256(a.vesting) * elapsed / VEST_DURATION;
            }
        }
        uint256 unlocked = uint256(a.immediate) + vestedAmount;
        uint256 claimed = a.claimed;
        return unlocked > claimed ? unlocked - claimed : 0;
    }
}
