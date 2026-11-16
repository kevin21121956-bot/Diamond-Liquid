// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Six-decimal USDC stand-in for Anvil deployments and tests. Never deploy this to a real network.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin (local)", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Local faucet.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
