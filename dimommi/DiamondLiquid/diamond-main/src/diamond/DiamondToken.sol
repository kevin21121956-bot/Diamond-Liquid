// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DiamondToken
/// @notice DIAMOND, the fixed-supply token of whitepaper §8.
/// @dev The whole 100,000,000 supply is minted once, in the constructor, to the genesis buckets. There is no
///      mint function and no burn function anywhere in this contract, so the minter role is not merely renounced —
///      it does not exist. "Loss-mint" rewards are a *release* of pre-issued DIAMOND from the 50,000,000 reserve,
///      never new supply (whitepaper §8).
///
///      Genesis allocation (whitepaper §8.1):
///        founder / team      15,000,000 (15%) — hard 18-month cliff from genesis, then performance-based
///                                               vesting tied to FDV (five tranches of 3,000,000 at 2×, 4×, 8×,
///                                               16× and 32× the agreed baseline FDV, measured by a sustained
///                                               TWAP, not a brief price spike)
///        early supporters    25,000,000 (25%) — những người ủng hộ ban đầu (early supporters)
///        Uniswap liquidity   10,000,000 (10%) — seeded into the Uniswap pool as the initial liquidity
///        loss reward reserve 50,000,000 (50%) — pre-issued loss-reward reserve for traders who lose
contract DiamondToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 100_000_000e18;

    address public immutable founderAllocation;
    address public immutable earlySupportersAllocation;
    address public immutable liquidityAllocation;
    address public immutable lossRewardReserve;

    event GenesisMinted(
        address indexed founder,
        address indexed earlySupporters,
        address indexed lossReserve,
        address liquidity,
        uint256 totalSupply
    );

    error BadGenesis();

    constructor(address founder_, address earlySupporters_, address liquidity_, address lossReserve_)
        ERC20("Diamond Liquid", "DIAMOND")
    {
        if (founder_ == address(0) || earlySupporters_ == address(0) || liquidity_ == address(0) || lossReserve_ == address(0)) {
            revert BadGenesis();
        }
        founderAllocation = founder_;
        earlySupportersAllocation = earlySupporters_;
        liquidityAllocation = liquidity_;
        lossRewardReserve = lossReserve_;

        _mint(founder_, 15_000_000e18); // 15%  founder / team, hard 18-month cliff then FDV-based tranche vesting
        _mint(earlySupporters_, 25_000_000e18); // 25%  early supporters (những người ủng hộ ban đầu)
        _mint(liquidity_, 10_000_000e18); // 10%  seeded into the Uniswap pool as the initial liquidity
        _mint(lossReserve_, 50_000_000e18); // 50%  pre-issued loss reward reserve

        emit GenesisMinted(founder_, earlySupporters_, lossReserve_, liquidity_, totalSupply());
    }

    /// @notice Always true: supply is fixed at genesis, minting is impossible, not just disabled.
    function minterDisabled() external pure returns (bool) {
        return true;
    }

    /// @notice Always true: the design does not burn, including buyback-acquired DIAMOND.
    function burnDisabled() external pure returns (bool) {
        return true;
    }
}
