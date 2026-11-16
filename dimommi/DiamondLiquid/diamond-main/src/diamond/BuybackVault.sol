// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ILossRewardInventory {
    /// @notice Credits DIAMOND actually received from an executed buyback as Phase 2 reward inventory.
    /// @dev Pulls `amount` of DIAMOND from the caller. Caller must have approved this contract.
    function addBuybackInventory(uint256 amount) external;
}

/// @title BuybackVault
/// @notice Sole custodian of every fee the venue collects: the 1.99% win fee, the impact (volatility) retention on
///         winning closes, and the 0.99% loss allocation. Nothing in this vault pays a trader; the pool nhà cái is
///         funded exclusively by settled losses (whitepaper §6, §7).
/// @dev Spendable ONLY through a 2-of-2 approval by the two immutable signers (founder and VC): one signer proposes a
///      swap, the other must confirm it, and the whole proposal (target, USDC amount, calldata) is executed exactly as
///      approved. The only execution shape that can succeed is one that leaves the vault holding MORE DIAMOND than
///      before; the DIAMOND received is credited straight into the LossRewardDistributor as Phase 2 buyback inventory
///      (whitepaper §8). A plain transfer, or a call that yields no DIAMOND, reverts. There is no withdraw path, no
///      owner and no pause: neither signer can move funds alone, and neither can sweep the vault.
contract BuybackVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PROPOSAL_TTL = 1 days;

    IERC20 public immutable usdc;
    IERC20 public immutable diamond;
    /// @notice The two and only signers, in fixed roles. Either may propose; the other must confirm.
    address public immutable founder;
    address public immutable vc;
    /// @notice The Phase 2 reward inventory ledger. Received DIAMOND is credited there, never elsewhere.
    address public immutable distributor;

    struct Proposal {
        address target; // swap target (e.g. a Uniswap router); caller-supplied, both signers inspect it
        uint256 usdcAmount; // USDC to approve and spend in the call
        bytes data; // exact calldata executed against `target`
        address proposer; // founder or vc
        uint64 createdAt; // for PROPOSAL_TTL expiry
    }

    /// @notice The single pending proposal slot. `propose` overwrites any stale proposal — it can never be used to
    ///         sneak an old proposal past confirmation, because confirming executes what is currently stored.
    Proposal public pending;

    event Proposed(address indexed proposer, address indexed target, uint256 usdcAmount, bytes data);
    event Cancelled(address indexed by, address indexed target, uint256 usdcAmount);
    event BuybackExecuted(address indexed target, uint256 usdcAmount, uint256 diamondBought);

    error NotSigner();
    error NotOtherSigner();
    error NoPendingProposal();
    error ProposalExpired();
    error ZeroAmount();
    error ZeroAddress();
    error CallFailed();
    error NoDiamondReceived();

    constructor(IERC20 usdc_, IERC20 diamond_, address founder_, address vc_, address distributor_) {
        if (
            address(usdc_) == address(0) || address(diamond_) == address(0) || founder_ == address(0)
                || vc_ == address(0) || distributor_ == address(0) || founder_ == vc_
        ) revert ZeroAddress();
        usdc = usdc_;
        diamond = diamond_;
        founder = founder_;
        vc = vc_;
        distributor = distributor_;
    }

    // ------------------------------------------------------------------ views

    function isSigner(address a) public view returns (bool) {
        return a == founder || a == vc;
    }

    /// @notice Unspent fees held right now (USDC). Purely informational.
    function custody() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ------------------------------------------------------------------ 2-of-2

    /// @notice Propose spending `usdcAmount` of the vault's USDC through `target` with exactly `data`.
    /// @dev Overwrites any existing pending proposal. Neither signer can execute alone: confirmation requires the
    ///      OTHER signer and executes the proposal currently stored, so an overwritten proposal is simply void.
    function propose(address target, uint256 usdcAmount, bytes calldata data) external {
        if (!isSigner(msg.sender)) revert NotSigner();
        if (target == address(0)) revert ZeroAddress();
        if (usdcAmount == 0) revert ZeroAmount();

        pending = Proposal({target: target, usdcAmount: usdcAmount, data: data, proposer: msg.sender, createdAt: uint64(block.timestamp)});
        emit Proposed(msg.sender, target, usdcAmount, data);
    }

    /// @notice Withdraw a pending proposal. Any signer may cancel; this is the reject path.
    function cancel() external {
        if (!isSigner(msg.sender)) revert NotSigner();
        Proposal memory p = pending;
        if (p.target == address(0)) revert NoPendingProposal();
        delete pending;
        emit Cancelled(msg.sender, p.target, p.usdcAmount);
    }

    /// @notice Confirm and execute the pending proposal. Only the signer who did NOT propose may confirm.
    /// @dev CEI order: the pending slot is cleared before any external call. The USDC approval is zeroed after the
    ///      call. The execution only succeeds if the vault's DIAMOND balance strictly increases; the received
    ///      DIAMOND is approved to the distributor and credited as Phase 2 buyback inventory in the same transaction.
    function confirm() external nonReentrant returns (uint256 diamondBought) {
        if (!isSigner(msg.sender)) revert NotSigner();
        Proposal memory p = pending;
        if (p.target == address(0)) revert NoPendingProposal();
        if (msg.sender == p.proposer) revert NotOtherSigner();
        if (block.timestamp > uint256(p.createdAt) + PROPOSAL_TTL) revert ProposalExpired();

        delete pending;

        uint256 diamondBefore = diamond.balanceOf(address(this));
        usdc.forceApprove(p.target, p.usdcAmount);
        (bool ok,) = p.target.call(p.data);
        if (!ok) revert CallFailed();
        usdc.forceApprove(p.target, 0);

        uint256 diamondAfter = diamond.balanceOf(address(this));
        if (diamondAfter <= diamondBefore) revert NoDiamondReceived();
        diamondBought = diamondAfter - diamondBefore;

        diamond.forceApprove(distributor, diamondBought);
        ILossRewardInventory(distributor).addBuybackInventory(diamondBought);

        emit BuybackExecuted(p.target, p.usdcAmount, diamondBought);
    }
}
