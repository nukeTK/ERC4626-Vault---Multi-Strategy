// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSD
 * @dev Mock ERC20 token with 6 decimals (matching USDC) for testing purposes
 */
contract MockUSD is ERC20 {
    uint8 private constant _DECIMALS = 6;

    constructor() ERC20("Mock USD", "mUSD") { }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * Overrides the default value of 18 to use 6 decimals like USDC.
     */
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /**
     * @dev Mints tokens to the specified account
     * @param account The address to mint tokens to
     * @param amount The amount of tokens to mint (in 6 decimals)
     */
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    /**
     * @dev Burns tokens from the specified account
     * @param account The address to burn tokens from
     * @param amount The amount of tokens to burn (in 6 decimals)
     */
    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
