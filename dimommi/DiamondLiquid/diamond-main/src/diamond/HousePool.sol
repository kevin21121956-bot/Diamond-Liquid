// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILossRewardDistributor} from "./interfaces/ILossRewardDistributor.sol";

/// @title HousePool
/// @notice The shared, unseeded USDC House Pool and the FIFO claim queue (whitepaper §1, §6, §7).
/// @dev No external capital ever enters this contract: there are no LP shares, no deposit path and no withdrawal path
///      out of pool cash other than paying winners and settling queued claims. The pool is enriched exclusively by
///      settled trader losses — 99.01% of every losing close lands here; the 0.99% remainder is transferred straight
///      to the `BuybackVault` (the 2-of-2 fee vault), as is the entire win fee and the impact retention on winning
///      closes. Cash is never counted twice. Three ledgers live here and each unit of USDC is in exactly one of them:
///
///        houseCash   - payout cash for winners; what can pay a winner right now
///        queuedClaims- *unfunded* net profit already owed to winners (a liability, no cash behind it yet)
///        (vault)     - all venue revenue, held in the separate BuybackVault, never in this contract
///
///      User margin never enters this contract: the engine holds margin and only moves it here when a position
///      settles (loss proceeds in, profit out, fees straight to the vault).
contract HousePool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice 0.99% of settled loss proceeds is allocated House-side to the buyback vault; 99.01% stays in the pool.
    uint256 public constant LOSS_BUYBACK_BPS = 99;

    IERC20 public immutable usdc;
    /// @notice The position engine (DiamondLiquid) allowed to move pool cash. Set once, right after deployment.
    address public engine;

    /// @notice The 2-of-2 fee vault. All venue revenue is transferred here at booking time; it never accrues here.
    address public immutable vault;

    address public distributor;

    uint256 public houseCash;
    uint256 public queuedClaims;

    struct Claim {
        address user;
        uint256 amount;
    }

    Claim[] private _claims;
    uint256 public claimHead;

    /// @notice Aggregate stats, for dashboards and the whitepaper's "display separately" requirement.
    uint256 public lifetimeLossProceeds;
    uint256 public lifetimeWinFees;
    uint256 public lifetimeProfitsPaid;
    uint256 public lifetimeProfitsQueued;

    event LossReceived(uint256 total, uint256 toHousePool, uint256 toBuyback);
    event ProfitSettled(address indexed user, uint256 paid, uint256 queued, uint256 winFeeBooked);
    event WinFeesBooked(uint256 winFeeBooked, uint256 impactRetainedBooked);
    event LossAllocBooked(uint256 amount);
    event ClaimQueued(uint256 indexed index, address indexed user, uint256 amount);
    event ClaimPaid(uint256 indexed index, address indexed user, uint256 amount);
    event ClaimsSettled(uint256 paidCount, uint256 paidAmount);
    event EngineSet(address indexed engine);
    event DistributorSet(address indexed distributor);

    error NotEngine();
    error NotAuthorised();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientCash();

    constructor(IERC20 usdc_, address initialOwner, address vault_) Ownable(initialOwner) {
        if (address(usdc_) == address(0) || vault_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        vault = vault_;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    // ------------------------------------------------------------------ views

    /// @notice Cash that could pay a winner right now (and only loss proceeds ever fill it).
    function availableCash() external view returns (uint256) {
        return houseCash;
    }

    function pendingClaimCount() external view returns (uint256) {
        return _claims.length - claimHead;
    }

    function claimAt(uint256 index) external view returns (Claim memory) {
        return _claims[index];
    }

    // ------------------------------------------------------------------ engine hooks

    /// @notice Book settled loss proceeds: 99.01% to the House Pool, 0.99% straight to the buyback vault.
    /// @dev Cash must already have been transferred in by the engine; this function only splits the ledger.
    function receiveLoss(uint256 amount) external onlyEngine {
        if (amount == 0) return;
        uint256 toBuyback = amount * LOSS_BUYBACK_BPS / BPS;
        uint256 toHouse = amount - toBuyback;

        houseCash += toHouse;
        lifetimeLossProceeds += amount;

        if (toBuyback != 0) {
            usdc.safeTransfer(vault, toBuyback);
            emit LossAllocBooked(toBuyback);
        }

        emit LossReceived(amount, toHouse, toBuyback);
        _notifyRevenue(0, toBuyback);
    }

    /// @notice Pay a winning close: `netProfit` to the trader; `winFee` and `impactRetained` are collected into the
    ///         buyback vault out of the cash that actually remains after the payout.
    /// @dev Profit is paid first; the fees are only booked out of cash that is there, and both go straight to the
    ///      vault — they never accrues to the pool. Anything that cannot be paid becomes a FIFO claim of the *net*
    ///      amount and no fee of any kind is booked. If any earlier claim remains, the entire new profit is queued
    ///      and no fee is booked, even when cash is available (whitepaper §5, §7).
    /// @return paid net profit transferred to the trader now
    /// @return queued net profit pushed onto the FIFO queue
    function settleProfit(address user, uint256 netProfit, uint256 winFee, uint256 impactRetained)
        external
        onlyEngine
        nonReentrant
        returns (uint256 paid, uint256 queued)
    {
        uint256 feeBooked = 0;
        uint256 impactBooked = 0;

        // Earlier queued claims have priority over every later profit and its fees. Do not scan the queue here:
        // settlement is permissionless and bounded by settleClaims, so a long queue cannot block position closing.
        if (queuedClaims != 0) {
            paid = 0;
        } else if (houseCash >= netProfit) {
            paid = netProfit;
            houseCash -= netProfit;
            uint256 cashLeft = houseCash;
            feeBooked = winFee <= cashLeft ? winFee : cashLeft;
            impactBooked = impactRetained <= cashLeft - feeBooked ? impactRetained : cashLeft - feeBooked;
            uint256 fees = feeBooked + impactBooked;
            if (fees != 0) {
                houseCash -= fees;
                usdc.safeTransfer(vault, fees);
                lifetimeWinFees += feeBooked;
                emit WinFeesBooked(feeBooked, impactBooked);
            }
        } else {
            paid = houseCash;
            houseCash = 0;
        }

        if (feeBooked != 0 || impactBooked != 0) {
            _notifyRevenue(feeBooked + impactBooked, 0);
        }

        if (paid != 0) {
            lifetimeProfitsPaid += paid;
            usdc.safeTransfer(user, paid);
        }

        queued = netProfit - paid;
        if (queued != 0) {
            lifetimeProfitsQueued += queued;
            queuedClaims += queued;
            _claims.push(Claim({user: user, amount: queued}));
            emit ClaimQueued(_claims.length - 1, user, queued);
        }

        emit ProfitSettled(user, paid, queued, feeBooked);
    }

    // ------------------------------------------------------------------ claims

    /// @notice Pay queued winning profits in FIFO order, as far as pool cash allows.
    /// @dev Permissionless: anyone (relayer, CRE workflow, winner) can push the queue forward. Partial head payments
    ///      stay at the head of the queue. Funded exclusively by settled losses.
    function settleClaims(uint256 maxCount) external nonReentrant returns (uint256 paidCount, uint256 paidAmount) {
        uint256 head = claimHead;
        uint256 len = _claims.length;

        while (paidCount < maxCount && head < len && houseCash > 0) {
            Claim storage c = _claims[head];
            uint256 available = houseCash;
            uint256 pay = c.amount < available ? c.amount : available;
            if (pay == 0) break;

            houseCash -= pay;
            queuedClaims -= pay;
            c.amount -= pay;
            paidAmount += pay;
            paidCount += 1;
            lifetimeProfitsPaid += pay;

            emit ClaimPaid(head, c.user, pay);
            usdc.safeTransfer(c.user, pay);

            if (c.amount == 0) {
                delete _claims[head];
                head += 1;
            }
        }

        claimHead = head;
        emit ClaimsSettled(paidCount, paidAmount);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Wire the position engine once. There is no path to re-point it afterwards.
    function setEngine(address engine_) external onlyOwner {
        if (engine != address(0)) revert NotAuthorised();
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
        emit EngineSet(engine_);
    }

    function setDistributor(address distributor_) external onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        distributor = distributor_;
        emit DistributorSet(address(distributor_));
    }

    function _notifyRevenue(uint256 winFeeCash, uint256 lossBuybackCash) internal {
        address d = distributor;
        if (d != address(0)) {
            ILossRewardDistributor(d).recordRevenue(winFeeCash, lossBuybackCash);
        }
    }
}
