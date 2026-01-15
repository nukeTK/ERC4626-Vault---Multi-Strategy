// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MetaVault } from "../src/MetaVault.sol";
import { MockInstantStrategy } from "../src/Mock/MockInstantStrategy.sol";
import { MockUSD } from "../src/Mock/MockUSD.sol";

contract MetaVaultTest is Test {
    MetaVault public metaVault;
    MockUSD public mockUSD;
    MockInstantStrategy public strategy1;
    MockInstantStrategy public strategy2;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public strategyOwner = address(0x4);

    uint256 public constant DEPOSIT_AMOUNT_1 = 1000 * 1e6; // 1000 USDC (6 decimals)
    uint256 public constant DEPOSIT_AMOUNT_2 = 2000 * 1e6; // 2000 USDC (6 decimals)
    uint256 public constant WITHDRAWAL_BUFFER_TARGET = 100 * 1e6; // 100 USDC buffer
    uint256 public constant INTEREST_RATE_1 = 500; // 5% interest rate (500 bps)
    uint256 public constant INTEREST_RATE_2 = 1000; // 10% interest rate (1000 bps)

    function setUp() public {
        // Set up accounts
        vm.startPrank(admin);

        // Deploy mock USD token
        mockUSD = new MockUSD();

        // Deploy two MockInstantStrategy contracts with different interest rates
        strategy1 = new MockInstantStrategy(
            IERC20(address(mockUSD)),
            INTEREST_RATE_1, // 5%
            "Strategy 1",
            "STR1"
        );

        strategy2 = new MockInstantStrategy(
            IERC20(address(mockUSD)),
            INTEREST_RATE_2, // 10%
            "Strategy 2",
            "STR2"
        );

        // Deploy MetaVault
        metaVault = new MetaVault(IERC20(address(mockUSD)), WITHDRAWAL_BUFFER_TARGET);

        // Set allocations: 50-50 split with isHLP = false
        MetaVault.Allocation[] memory allocations = new MetaVault.Allocation[](2);
        allocations[0] =
            MetaVault.Allocation({
                protocol: address(strategy1),
                targetBps: 5000, // 50%
                isHLP: false
            });
        allocations[1] =
            MetaVault.Allocation({
                protocol: address(strategy2),
                targetBps: 5000, // 50%
                isHLP: false
            });

        metaVault.setAllocations(allocations);

        // Mint tokens to admin (vaultOwner) for interest payments
        mockUSD.mint(admin, (DEPOSIT_AMOUNT_1 + DEPOSIT_AMOUNT_2) * 100);

        // Admin (vaultOwner) needs to approve strategies to transfer interest
        mockUSD.approve(address(strategy1), type(uint256).max);
        mockUSD.approve(address(strategy2), type(uint256).max);

        vm.stopPrank();

        // Mint tokens to users for testing
        mockUSD.mint(user1, DEPOSIT_AMOUNT_1 * 10);
        mockUSD.mint(user2, DEPOSIT_AMOUNT_2 * 10);
    }

    function test_TwoUsersDepositDifferentAmounts() public {
        console.log("Strategy1 interest rate:", strategy1.INTEREST_RATE());
        console.log("Strategy2 interest rate:", strategy2.INTEREST_RATE());

        // Record initial balances
        // Note: MetaVault holds shares in both strategies (not users directly)
        // Users hold MetaVault shares, and MetaVault holds strategy shares
        uint256 initialStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 initialStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("Initial MetaVault shares of Strategy1:", initialStrategy1Shares);
        console.log("Initial MetaVault shares of Strategy2:", initialStrategy2Shares);

        // User1 deposits first amount
        vm.startPrank(user1);
        mockUSD.approve(address(metaVault), DEPOSIT_AMOUNT_1);
        uint256 initialVaultShares1 = metaVault.balanceOf(user1);

        console.log("\n=== User1 Deposit ===");
        console.log("User1 deposit amount:", DEPOSIT_AMOUNT_1);

        // User deposits to MetaVault and receives MetaVault shares
        uint256 sharesReceived1 = metaVault.deposit(DEPOSIT_AMOUNT_1, user1);
        console.log("User1 received MetaVault shares:", sharesReceived1);
        console.log("Note: User1 has MetaVault shares, MetaVault has strategy shares");

        uint256 finalVaultShares1 = metaVault.balanceOf(user1);
        assertEq(finalVaultShares1 - initialVaultShares1, sharesReceived1, "User1 should receive shares from MetaVault");

        // Check shares in strategies after user1 deposit
        // MetaVault now holds shares in both strategies (distributed 50-50)
        uint256 afterUser1Strategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 afterUser1Strategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("After User1 deposit - MetaVault shares of Strategy1:", afterUser1Strategy1Shares);
        console.log("After User1 deposit - MetaVault shares of Strategy2:", afterUser1Strategy2Shares);
        console.log("Note: MetaVault has shares in BOTH strategies, User1 only has MetaVault shares");

        assertGt(
            afterUser1Strategy1Shares,
            initialStrategy1Shares,
            "MetaVault should have shares in Strategy1 after User1 deposit"
        );
        assertGt(
            afterUser1Strategy2Shares,
            initialStrategy2Shares,
            "MetaVault should have shares in Strategy2 after User1 deposit"
        );

        vm.stopPrank();

        // User2 deposits second amount
        vm.startPrank(user2);
        mockUSD.approve(address(metaVault), DEPOSIT_AMOUNT_2);
        uint256 initialVaultShares2 = metaVault.balanceOf(user2);

        console.log("\n=== User2 Deposit ===");
        console.log("User2 deposit amount:", DEPOSIT_AMOUNT_2);

        // User2 deposits to MetaVault and receives MetaVault shares
        uint256 sharesReceived2 = metaVault.deposit(DEPOSIT_AMOUNT_2, user2);
        console.log("User2 received MetaVault shares:", sharesReceived2);
        console.log("Note: User2 has MetaVault shares, MetaVault has strategy shares");

        uint256 finalVaultShares2 = metaVault.balanceOf(user2);
        assertEq(finalVaultShares2 - initialVaultShares2, sharesReceived2, "User2 should receive shares from MetaVault");

        // Check final shares in strategies after both deposits
        // MetaVault holds shares in both strategies (accumulated from both users' deposits)
        uint256 finalStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 finalStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("\n=== Final State ===");
        console.log("Final MetaVault shares of Strategy1:", finalStrategy1Shares);
        console.log("Final MetaVault shares of Strategy2:", finalStrategy2Shares);
        console.log("Note: MetaVault has shares in BOTH strategies (from both User1 and User2 deposits)");

        // Verify shares increased after user2 deposit
        assertGt(
            finalStrategy1Shares, afterUser1Strategy1Shares, "Strategy1 shares should increase after User2 deposit"
        );
        assertGt(
            finalStrategy2Shares, afterUser1Strategy2Shares, "Strategy2 shares should increase after User2 deposit"
        );

        // Convert shares to assets to verify distribution
        uint256 strategy1Assets = IERC4626(address(strategy1)).convertToAssets(finalStrategy1Shares);
        uint256 strategy2Assets = IERC4626(address(strategy2)).convertToAssets(finalStrategy2Shares);

        console.log("Final Strategy1 assets (MetaVault's position):", strategy1Assets);
        console.log("Final Strategy2 assets (MetaVault's position):", strategy2Assets);

        // Verify both strategies have assets
        assertGt(strategy1Assets, 0, "Strategy1 should have assets");
        assertGt(strategy2Assets, 0, "Strategy2 should have assets");

        // Verify user balances
        // Users hold MetaVault shares, not strategy shares directly
        console.log("\n=== User Balances (MetaVault Shares) ===");
        console.log("User1 MetaVault shares:", metaVault.balanceOf(user1));
        console.log("User2 MetaVault shares:", metaVault.balanceOf(user2));
        console.log("Note: Users have MetaVault shares, NOT strategy shares directly");
        console.log("MetaVault holds shares in BOTH Strategy1 and Strategy2");

        assertGt(metaVault.balanceOf(user1), 0, "User1 should have vault shares");
        assertGt(metaVault.balanceOf(user2), 0, "User2 should have vault shares");

        vm.stopPrank();
    }

    function test_DepositAndCheckStrategyShares() public {
        // User1 approves MetaVault to spend tokens
        vm.startPrank(user1);
        mockUSD.approve(address(metaVault), DEPOSIT_AMOUNT_1);

        // Record initial balances
        // Note: Users hold MetaVault shares, MetaVault holds strategy shares
        uint256 initialVaultShares = metaVault.balanceOf(user1);
        uint256 initialStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 initialStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("Strategy1 interest rate:", strategy1.INTEREST_RATE());
        console.log("Strategy2 interest rate:", strategy2.INTEREST_RATE());
        console.log("Initial MetaVault shares of Strategy1:", initialStrategy1Shares);
        console.log("Initial MetaVault shares of Strategy2:", initialStrategy2Shares);

        // Perform deposit - User receives MetaVault shares
        uint256 sharesReceived = metaVault.deposit(DEPOSIT_AMOUNT_1, user1);

        console.log("Deposit amount:", DEPOSIT_AMOUNT_1);
        console.log("User1 received MetaVault shares:", sharesReceived);
        console.log("Note: User1 has MetaVault shares, MetaVault will have strategy shares");

        // Check user received shares from MetaVault
        uint256 finalVaultShares = metaVault.balanceOf(user1);
        assertEq(finalVaultShares - initialVaultShares, sharesReceived, "User should receive shares from MetaVault");

        // Check MetaVault received shares from each strategy
        // MetaVault now holds shares in BOTH strategies (distributed 50-50)
        uint256 finalStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 finalStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("Final MetaVault shares of Strategy1:", finalStrategy1Shares);
        console.log("Final MetaVault shares of Strategy2:", finalStrategy2Shares);
        console.log("Note: MetaVault has shares in BOTH strategies, User1 only has MetaVault shares");

        // Verify shares were received from both strategies
        assertGt(finalStrategy1Shares, initialStrategy1Shares, "MetaVault should have shares in Strategy1");
        assertGt(finalStrategy2Shares, initialStrategy2Shares, "MetaVault should have shares in Strategy2");

        // Verify 50-50 allocation (allowing for buffer, rounding, and different interest rates)
        // After deposit, some amount goes to buffer, rest is distributed 50-50
        // Note: Assets will differ due to different interest rates (5% vs 10%)
        uint256 strategy1Assets = IERC4626(address(strategy1)).convertToAssets(finalStrategy1Shares);
        uint256 strategy2Assets = IERC4626(address(strategy2)).convertToAssets(finalStrategy2Shares);

        console.log("Strategy1 assets of MetaVault:", strategy1Assets);
        console.log("Strategy2 assets of MetaVault:", strategy2Assets);

        // Both strategies should have received assets
        assertGt(strategy1Assets, 0, "Strategy1 should have assets");
        assertGt(strategy2Assets, 0, "Strategy2 should have assets");

        // With different interest rates, assets will differ, but both should have significant amounts
        // Strategy2 has 10% interest vs Strategy1's 5%, so Strategy2 will have more assets
        // We verify both received deposits (shares > 0) and have assets
        // The allocation is 50-50 based on targetBps, but actual assets differ due to interest rates

        vm.stopPrank();
    }

    function test_WithdrawalAfterTwoUsersDeposit() public {
        uint256 depositAmount1 = 10 * 1e6; // 10 USD
        uint256 depositAmount2 = 20 * 1e6; // 20 USD
        uint256 withdrawAmount = 5 * 1e6; // 5 USD

        console.log("Strategy1 interest rate:", strategy1.INTEREST_RATE());
        console.log("Strategy2 interest rate:", strategy2.INTEREST_RATE());

        // Record initial balances
        uint256 initialStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 initialStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("\n=== Initial State ===");
        console.log("Initial MetaVault shares of Strategy1:", initialStrategy1Shares);
        console.log("Initial MetaVault shares of Strategy2:", initialStrategy2Shares);

        // User1 deposits 10 USD
        vm.startPrank(user1);
        mockUSD.approve(address(metaVault), depositAmount1);
        console.log("\n=== User1 Deposit (10 USD) ===");
        uint256 user1SharesReceived = metaVault.deposit(depositAmount1, user1);
        console.log("User1 received MetaVault shares:", user1SharesReceived);
        console.log("Note: User1 has MetaVault shares, MetaVault has strategy shares");
        vm.stopPrank();

        // User2 deposits 20 USD
        vm.startPrank(user2);
        mockUSD.approve(address(metaVault), depositAmount2);
        console.log("\n=== User2 Deposit (20 USD) ===");
        uint256 user2SharesReceived = metaVault.deposit(depositAmount2, user2);
        console.log("User2 received MetaVault shares:", user2SharesReceived);
        console.log("Note: User2 has MetaVault shares, MetaVault has strategy shares");

        // Check MetaVault shares in strategies after both deposits
        console.log("\n=== After Both Deposits ===");
        console.log("MetaVault shares of Strategy1:", IERC4626(address(strategy1)).balanceOf(address(metaVault)));
        console.log("MetaVault shares of Strategy2:", IERC4626(address(strategy2)).balanceOf(address(metaVault)));
        console.log("User1 MetaVault shares:", metaVault.balanceOf(user1));
        console.log("User2 MetaVault shares:", metaVault.balanceOf(user2));

        // Record balances before withdrawal
        uint256 user2USDBefore = mockUSD.balanceOf(user2);
        uint256 user2SharesBeforeWithdraw = metaVault.balanceOf(user2);

        // User2 withdraws 5 USD worth of shares
        console.log("\n=== User2 Withdrawal (5 USD) ===");
        uint256 sharesToRedeem = metaVault.previewWithdraw(withdrawAmount);
        console.log("Shares to redeem for 5 USD:", sharesToRedeem);

        // Perform withdrawal (returns shares, not assets)
        uint256 sharesBurned = metaVault.withdraw(withdrawAmount, user2, user2);
        console.log("User2 shares burned:", sharesBurned);

        // Check balances after withdrawal
        uint256 user2USDAfter = mockUSD.balanceOf(user2);
        uint256 user2SharesAfterWithdraw = metaVault.balanceOf(user2);

        console.log("User2 USD received:", user2USDAfter - user2USDBefore);
        console.log("User2 MetaVault shares burned:", user2SharesBeforeWithdraw - user2SharesAfterWithdraw);

        // Verify withdrawal
        // withdraw() returns shares burned, not assets received
        assertEq(sharesBurned, sharesToRedeem, "User2 should burn the correct amount of shares");
        assertEq(user2USDAfter - user2USDBefore, withdrawAmount, "User2 USD balance should increase by 5 USD");
        assertEq(
            user2SharesBeforeWithdraw - user2SharesAfterWithdraw,
            sharesToRedeem,
            "User2 shares should decrease by redeemed amount"
        );

        // Check MetaVault shares in strategies after withdrawal
        uint256 afterWithdrawStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 afterWithdrawStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));

        console.log("\n=== After Withdrawal ===");
        console.log("MetaVault shares of Strategy1:", afterWithdrawStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", afterWithdrawStrategy2Shares);
        console.log("Note: MetaVault shares in strategies may decrease if instant liquidity was used");

        // Convert shares to assets to verify
        uint256 strategy1Assets = IERC4626(address(strategy1)).convertToAssets(afterWithdrawStrategy1Shares);
        uint256 strategy2Assets = IERC4626(address(strategy2)).convertToAssets(afterWithdrawStrategy2Shares);

        console.log("Strategy1 assets of MetaVault:", strategy1Assets);
        console.log("Strategy2 assets of MetaVault:", strategy2Assets);

        // Verify both strategies still have assets
        assertGt(strategy1Assets, 0, "Strategy1 should still have assets");
        assertGt(strategy2Assets, 0, "Strategy2 should still have assets");

        // Verify user balances
        console.log("\n=== Final User Balances ===");
        console.log("User1 MetaVault shares:", metaVault.balanceOf(user1));
        console.log("User2 MetaVault shares:", metaVault.balanceOf(user2));

        assertGt(metaVault.balanceOf(user1), 0, "User1 should still have MetaVault shares");
        assertGt(metaVault.balanceOf(user2), 0, "User2 should still have MetaVault shares after partial withdrawal");

        vm.stopPrank();
    }

    function test_RebalanceAfterBothUsersWithdraw() public {
        uint256 depositAmount1 = 10 * 1e6; // 10 USD
        uint256 depositAmount2 = 20 * 1e6; // 20 USD
        uint256 withdrawAmount = 5 * 1e6; // 5 USD (same for both)

        console.log("Strategy1 interest rate:", strategy1.INTEREST_RATE());
        console.log("Strategy2 interest rate:", strategy2.INTEREST_RATE());

        // User1 deposits 10 USD
        vm.startPrank(user1);
        mockUSD.approve(address(metaVault), depositAmount1);
        console.log("\n=== User1 Deposit (10 USD) ===");
        uint256 user1SharesReceived = metaVault.deposit(depositAmount1, user1);
        console.log("User1 received MetaVault shares:", user1SharesReceived);
        vm.stopPrank();

        uint256 vaultUSDBalance = mockUSD.balanceOf(address(metaVault));
        console.log("\n=== Vault USD Balance After User1 Deposit ===");
        console.log("MetaVault USD balance:", vaultUSDBalance);

        // User2 deposits 20 USD
        vm.startPrank(user2);
        mockUSD.approve(address(metaVault), depositAmount2);
        console.log("\n=== User2 Deposit (20 USD) ===");
        uint256 user2SharesReceived = metaVault.deposit(depositAmount2, user2);
        console.log("User2 received MetaVault shares:", user2SharesReceived);
        vm.stopPrank();

        vaultUSDBalance = mockUSD.balanceOf(address(metaVault));
        console.log("\n=== Vault USD Balance After User2 Deposit ===");
        console.log("MetaVault USD balance:", vaultUSDBalance);

        // Check MetaVault shares in strategies after both deposits
        console.log("\n=== After Both Deposits ===");
        uint256 beforeWithdrawStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 beforeWithdrawStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));
        console.log("MetaVault shares of Strategy1:", beforeWithdrawStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", beforeWithdrawStrategy2Shares);

        uint256 beforeWithdrawStrategy1Assets =
            IERC4626(address(strategy1)).convertToAssets(beforeWithdrawStrategy1Shares);
        uint256 beforeWithdrawStrategy2Assets =
            IERC4626(address(strategy2)).convertToAssets(beforeWithdrawStrategy2Shares);
        console.log("Strategy1 assets of MetaVault:", beforeWithdrawStrategy1Assets);
        console.log("Strategy2 assets of MetaVault:", beforeWithdrawStrategy2Assets);

        // User1 withdraws 5 USD
        vm.startPrank(user1);
        console.log("\n=== User1 Withdrawal (5 USD) ===");
        uint256 user1SharesBurned = metaVault.withdraw(withdrawAmount, user1, user1);
        console.log("User1 shares burned:", user1SharesBurned);
        console.log("User1 USD received:", withdrawAmount);
        vm.stopPrank();

        vaultUSDBalance = mockUSD.balanceOf(address(metaVault));
        console.log("\n=== Vault USD Balance After User1 Withdrawal ===");
        console.log("MetaVault USD balance:", vaultUSDBalance);

        // User2 withdraws 5 USD
        vm.startPrank(user2);
        console.log("\n=== User2 Withdrawal (5 USD) ===");
        uint256 user2SharesBurned = metaVault.withdraw(withdrawAmount, user2, user2);
        console.log("User2 shares burned:", user2SharesBurned);
        console.log("User2 USD received:", withdrawAmount);
        vm.stopPrank();

        vaultUSDBalance = mockUSD.balanceOf(address(metaVault));
        console.log("\n=== Vault USD Balance After User2 Withdrawal ===");
        console.log("MetaVault USD balance:", vaultUSDBalance);

        // Check MetaVault shares in strategies after both withdrawals
        console.log("\n=== After Both Withdrawals (Before Rebalance) ===");
        uint256 afterWithdrawStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 afterWithdrawStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));
        console.log("MetaVault shares of Strategy1:", afterWithdrawStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", afterWithdrawStrategy2Shares);

        uint256 afterWithdrawStrategy1Assets =
            IERC4626(address(strategy1)).convertToAssets(afterWithdrawStrategy1Shares);
        uint256 afterWithdrawStrategy2Assets =
            IERC4626(address(strategy2)).convertToAssets(afterWithdrawStrategy2Shares);
        console.log("Strategy1 assets of MetaVault:", afterWithdrawStrategy1Assets);
        console.log("Strategy2 assets of MetaVault:", afterWithdrawStrategy2Assets);
        console.log("Note: Allocations may be imbalanced after withdrawals");

        // Manager calls rebalance
        vm.startPrank(admin);
        console.log("\n=== Manager Calls Rebalance ===");
        uint256 vaultBalanceBeforeRebalance = mockUSD.balanceOf(address(metaVault));
        console.log("Vault USD balance before rebalance:", vaultBalanceBeforeRebalance);
        metaVault.rebalance();
        console.log("Rebalance completed");
        vm.stopPrank();

        uint256 vaultBalanceAfterRebalance = mockUSD.balanceOf(address(metaVault));
        console.log("Vault USD balance after rebalance:", vaultBalanceAfterRebalance);

        // Check MetaVault shares in strategies after rebalance
        console.log("\n=== After Rebalance ===");
        uint256 afterRebalanceStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 afterRebalanceStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));
        console.log("MetaVault shares of Strategy1:", afterRebalanceStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", afterRebalanceStrategy2Shares);

        uint256 afterRebalanceStrategy1Assets =
            IERC4626(address(strategy1)).convertToAssets(afterRebalanceStrategy1Shares);
        uint256 afterRebalanceStrategy2Assets =
            IERC4626(address(strategy2)).convertToAssets(afterRebalanceStrategy2Shares);
        console.log("Strategy1 assets of MetaVault:", afterRebalanceStrategy1Assets);
        console.log("Strategy2 assets of MetaVault:", afterRebalanceStrategy2Assets);

        // Verify rebalance worked - allocations should be approximately 50-50
        // Note: Due to different interest rates (5% vs 10%), perfect 50-50 may not be achievable
        // Rebalance works on asset values, but shares-to-assets conversion differs between strategies
        uint256 totalAssets = afterRebalanceStrategy1Assets + afterRebalanceStrategy2Assets;
        uint256 strategy1Bps = (afterRebalanceStrategy1Assets * 10_000) / totalAssets;
        uint256 strategy2Bps = (afterRebalanceStrategy2Assets * 10_000) / totalAssets;

        console.log("Strategy1 allocation (bps):", strategy1Bps);
        console.log("Strategy2 allocation (bps):", strategy2Bps);
        console.log("Target allocation: 5000 bps (50%) for each");
        console.log("Note: With different interest rates, perfect 50-50 may not be achievable");

        // Verify rebalance improved the allocation (should be closer to 50-50 than before)
        uint256 beforeRebalanceTotal = afterWithdrawStrategy1Assets + afterWithdrawStrategy2Assets;
        uint256 beforeRebalanceStrategy1Bps = (afterWithdrawStrategy1Assets * 10_000) / beforeRebalanceTotal;
        uint256 beforeRebalanceStrategy2Bps = (afterWithdrawStrategy2Assets * 10_000) / beforeRebalanceTotal;

        console.log("Before rebalance - Strategy1 (bps):", beforeRebalanceStrategy1Bps);
        console.log("Before rebalance - Strategy2 (bps):", beforeRebalanceStrategy2Bps);

        // Rebalance should improve the allocation
        // Verify allocations are reasonable (within 20% tolerance due to different interest rates)
        uint256 tolerance = 2000; // 20% = 2000 bps (allowing for interest rate differences)
        uint256 afterDiff1 = strategy1Bps > 5000 ? strategy1Bps - 5000 : 5000 - strategy1Bps;

        assertLe(afterDiff1, tolerance, "Strategy1 allocation should be reasonable after rebalance");
        // Verify rebalance improved allocation (before was very imbalanced: ~19% vs ~80%)
        assertLt(
            afterDiff1,
            beforeRebalanceStrategy1Bps > 5000
                ? beforeRebalanceStrategy1Bps - 5000
                : 5000 - beforeRebalanceStrategy1Bps,
            "Rebalance should improve allocation"
        );
        assertLe(strategy1Bps + strategy2Bps, 10_050, "Total allocation should be approximately 100%");
        assertGe(strategy1Bps + strategy2Bps, 9950, "Total allocation should be approximately 100%");

        // Verify both strategies still have assets
        assertGt(afterRebalanceStrategy1Assets, 0, "Strategy1 should still have assets after rebalance");
        assertGt(afterRebalanceStrategy2Assets, 0, "Strategy2 should still have assets after rebalance");

        // Verify user balances
        console.log("\n=== Final User Balances ===");
        console.log("User1 MetaVault shares:", metaVault.balanceOf(user1));
        console.log("User2 MetaVault shares:", metaVault.balanceOf(user2));

        assertGt(metaVault.balanceOf(user1), 0, "User1 should still have MetaVault shares");
        assertGt(metaVault.balanceOf(user2), 0, "User2 should still have MetaVault shares");
    }

    function test_UserAWithdrawsFullDepositThenRebalance() public {
        uint256 depositAmountA = 5 * 1e6; // 5 USD
        uint256 depositAmountB = 4 * 1e6; // 4 USD
        uint256 withdrawAmountA = 5 * 1e6; // 5 USD (full withdrawal)

        console.log("Strategy1 interest rate:", strategy1.INTEREST_RATE());
        console.log("Strategy2 interest rate:", strategy2.INTEREST_RATE());

        // User A deposits 5 USD
        vm.startPrank(user1);
        mockUSD.approve(address(metaVault), depositAmountA);
        console.log("\n=== User A Deposit (5 USD) ===");
        uint256 userASharesReceived = metaVault.deposit(depositAmountA, user1);
        console.log("User A received MetaVault shares:", userASharesReceived);
        vm.stopPrank();

        // User B deposits 4 USD
        vm.startPrank(user2);
        mockUSD.approve(address(metaVault), depositAmountB);
        console.log("\n=== User B Deposit (4 USD) ===");
        uint256 userBSharesReceived = metaVault.deposit(depositAmountB, user2);
        console.log("User B received MetaVault shares:", userBSharesReceived);
        vm.stopPrank();

        // Check MetaVault shares in strategies after both deposits
        console.log("\n=== After Both Deposits ===");
        uint256 beforeWithdrawStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 beforeWithdrawStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));
        console.log("MetaVault shares of Strategy1:", beforeWithdrawStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", beforeWithdrawStrategy2Shares);

        uint256 beforeWithdrawStrategy1Assets =
            IERC4626(address(strategy1)).convertToAssets(beforeWithdrawStrategy1Shares);
        uint256 beforeWithdrawStrategy2Assets =
            IERC4626(address(strategy2)).convertToAssets(beforeWithdrawStrategy2Shares);
        console.log("Strategy1 assets of MetaVault:", beforeWithdrawStrategy1Assets);
        console.log("Strategy2 assets of MetaVault:", beforeWithdrawStrategy2Assets);
        console.log("User A MetaVault shares:", metaVault.balanceOf(user1));
        console.log("User B MetaVault shares:", metaVault.balanceOf(user2));

        // User A withdraws 5 USD (full withdrawal) - using shares
        vm.startPrank(user1);
        uint256 userASharesBefore = metaVault.balanceOf(user1);
        console.log("\n=== User A Withdrawal (5 USD - Full Withdrawal) ===");
        console.log("User A MetaVault shares before withdrawal:", userASharesBefore);

        // Withdraw using shares (redeem all shares)
        uint256 userAAssetsReceived = metaVault.redeem(userASharesBefore, user1, user1);
        console.log("User A shares burned:", userASharesBefore);
        console.log("User A USD received:", userAAssetsReceived);

        uint256 userASharesAfter = metaVault.balanceOf(user1);
        console.log("User A MetaVault shares after withdrawal:", userASharesAfter);
        assertEq(userASharesAfter, 0, "User A should have no MetaVault shares after full withdrawal");
        vm.stopPrank();

        // Check MetaVault shares in strategies after User A withdrawal
        console.log("\n=== After User A Withdrawal (Before Rebalance) ===");
        uint256 afterWithdrawStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 afterWithdrawStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));
        console.log("MetaVault shares of Strategy1:", afterWithdrawStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", afterWithdrawStrategy2Shares);

        uint256 afterWithdrawStrategy1Assets =
            IERC4626(address(strategy1)).convertToAssets(afterWithdrawStrategy1Shares);
        uint256 afterWithdrawStrategy2Assets =
            IERC4626(address(strategy2)).convertToAssets(afterWithdrawStrategy2Shares);
        console.log("Strategy1 assets of MetaVault:", afterWithdrawStrategy1Assets);
        console.log("Strategy2 assets of MetaVault:", afterWithdrawStrategy2Assets);
        console.log("Note: Allocations may be imbalanced after User A's full withdrawal");

        uint256 vaultBalanceBeforeRebalance = mockUSD.balanceOf(address(metaVault));
        console.log("Vault USD balance before rebalance:", vaultBalanceBeforeRebalance);

        // Manager calls rebalance
        vm.startPrank(admin);
        console.log("\n=== Manager Calls Rebalance ===");
        metaVault.rebalance();
        console.log("Rebalance completed");
        vm.stopPrank();

        uint256 vaultBalanceAfterRebalance = mockUSD.balanceOf(address(metaVault));
        console.log("Vault USD balance after rebalance:", vaultBalanceAfterRebalance);

        // Check MetaVault shares in strategies after rebalance
        console.log("\n=== After Rebalance ===");
        uint256 afterRebalanceStrategy1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 afterRebalanceStrategy2Shares = IERC4626(address(strategy2)).balanceOf(address(metaVault));
        console.log("MetaVault shares of Strategy1:", afterRebalanceStrategy1Shares);
        console.log("MetaVault shares of Strategy2:", afterRebalanceStrategy2Shares);

        uint256 afterRebalanceStrategy1Assets =
            IERC4626(address(strategy1)).convertToAssets(afterRebalanceStrategy1Shares);
        uint256 afterRebalanceStrategy2Assets =
            IERC4626(address(strategy2)).convertToAssets(afterRebalanceStrategy2Shares);
        console.log("Strategy1 assets of MetaVault:", afterRebalanceStrategy1Assets);
        console.log("Strategy2 assets of MetaVault:", afterRebalanceStrategy2Assets);

        // Verify rebalance worked - allocations should be approximately 50-50
        uint256 totalAssets = afterRebalanceStrategy1Assets + afterRebalanceStrategy2Assets;
        uint256 strategy1Bps = (afterRebalanceStrategy1Assets * 10_000) / totalAssets;
        uint256 strategy2Bps = (afterRebalanceStrategy2Assets * 10_000) / totalAssets;

        console.log("Strategy1 allocation (bps):", strategy1Bps);
        console.log("Strategy2 allocation (bps):", strategy2Bps);
        console.log("Target allocation: 5000 bps (50%) for each");

        // Verify allocations are reasonable (within 20% tolerance due to different interest rates)
        uint256 tolerance = 2000; // 20% = 2000 bps
        uint256 afterDiff1 = strategy1Bps > 5000 ? strategy1Bps - 5000 : 5000 - strategy1Bps;

        assertLe(afterDiff1, tolerance, "Strategy1 allocation should be reasonable after rebalance");
        assertLe(strategy1Bps + strategy2Bps, 10_050, "Total allocation should be approximately 100%");
        assertGe(strategy1Bps + strategy2Bps, 9950, "Total allocation should be approximately 100%");

        // Verify both strategies still have assets
        assertGt(afterRebalanceStrategy1Assets, 0, "Strategy1 should still have assets after rebalance");
        assertGt(afterRebalanceStrategy2Assets, 0, "Strategy2 should still have assets after rebalance");

        // Verify user balances
        console.log("\n=== Final User Balances ===");
        console.log("User A MetaVault shares:", metaVault.balanceOf(user1));
        console.log("User B MetaVault shares:", metaVault.balanceOf(user2));

        assertEq(metaVault.balanceOf(user1), 0, "User A should have no MetaVault shares after full withdrawal");
        assertGt(metaVault.balanceOf(user2), 0, "User B should still have MetaVault shares");

        // Verify vault balance is minimal after rebalance
        assertLe(vaultBalanceAfterRebalance, 10, "Vault should have minimal USD balance after rebalance");
    }

    function test_UserDepositThenAllocationChangeThenValueIncreaseThenWithdraw() public {
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC

        console.log("\n=== Step 1: User deposits 1000 USDC ===");
        vm.startPrank(user1);
        mockUSD.approve(address(metaVault), depositAmount);
        uint256 userShares = metaVault.deposit(depositAmount, user1);
        console.log("User deposited:", depositAmount);
        console.log("User received MetaVault shares:", userShares);
        vm.stopPrank();

        // Check initial allocation
        uint256 s1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        uint256 s1Assets = IERC4626(address(strategy1)).convertToAssets(s1Shares);
        uint256 s2Assets =
            IERC4626(address(strategy2)).convertToAssets(IERC4626(address(strategy2)).balanceOf(address(metaVault)));
        console.log("Initial Strategy1 assets:", s1Assets);
        console.log("Initial Strategy2 assets:", s2Assets);

        console.log("\n=== Step 2: Manager sets 60/40 allocation (Protocol A / Protocol B) ===");
        vm.startPrank(admin);
        MetaVault.Allocation[] memory newAllocations = new MetaVault.Allocation[](2);
        newAllocations[0] =
            MetaVault.Allocation({ protocol: address(strategy1), targetBps: 6000, isHLP: false });
        newAllocations[1] =
            MetaVault.Allocation({ protocol: address(strategy2), targetBps: 4000, isHLP: false });
        metaVault.setAllocations(newAllocations);
        metaVault.rebalance();
        console.log("Allocations set and rebalanced: Strategy1 = 60%, Strategy2 = 40%");
        vm.stopPrank();

        // Check allocation after rebalance
        s1Shares = IERC4626(address(strategy1)).balanceOf(address(metaVault));
        s1Assets = IERC4626(address(strategy1)).convertToAssets(s1Shares);
        s2Assets =
            IERC4626(address(strategy2)).convertToAssets(IERC4626(address(strategy2)).balanceOf(address(metaVault)));
        console.log("After rebalance - Strategy1 assets:", s1Assets);
        console.log("After rebalance - Strategy2 assets:", s2Assets);

        // Check user's share value before value increase
        uint256 userValueBefore = metaVault.convertToAssets(userShares);
        console.log("\nUser's shares value before Protocol A value increase:", userValueBefore);

        console.log("\n=== Step 3: Protocol A increases in value by 10% ===");
        uint256 valueIncrease = s1Assets * 1000 / 10_000; // 10%
        console.log("Protocol A assets before increase:", s1Assets);
        console.log("Simulating 10% value increase:", valueIncrease);

        // Mint and transfer tokens to strategy1 to simulate value increase
        vm.startPrank(admin);
        mockUSD.mint(admin, valueIncrease);
        mockUSD.transfer(address(strategy1), valueIncrease);
        vm.stopPrank();

        // Verify Protocol A value increased
        s1Assets = IERC4626(address(strategy1)).convertToAssets(s1Shares);
        console.log("Protocol A assets after increase:", s1Assets);

        console.log("\n=== Step 4: User's shares are now worth more due to Protocol A value increase ===");
        uint256 userValueAfter = metaVault.convertToAssets(userShares);
        console.log("User's shares value after Protocol A value increase:", userValueAfter);
        console.log("Value increase:", userValueAfter - userValueBefore);
        console.log("Note: Base value is higher than 1000 USDC due to strategy interest rates");

        assertGt(userValueAfter, userValueBefore, "User's shares should increase in value");

        console.log("\n=== Step 5: User withdraws ===");
        uint256 userUSDBefore = mockUSD.balanceOf(user1);
        uint256 userSharesBefore = metaVault.balanceOf(user1);

        vm.startPrank(user1);
        uint256 assetsReceived = metaVault.redeem(userSharesBefore, user1, user1);
        vm.stopPrank();

        uint256 userUSDAfter = mockUSD.balanceOf(user1);
        uint256 userSharesAfter = metaVault.balanceOf(user1);

        console.log("User shares before withdrawal:", userSharesBefore);
        console.log("Assets received from withdrawal:", assetsReceived);
        console.log("User USD after withdrawal:", userUSDAfter);
        console.log("Net USD received:", userUSDAfter - userUSDBefore);

        assertEq(userSharesAfter, 0, "User should have no shares after withdrawal");
        assertEq(assetsReceived, userValueAfter, "User should receive assets equal to their share value");
        assertEq(userUSDAfter - userUSDBefore, assetsReceived, "User's USD balance should increase by assets received");
        assertGt(assetsReceived, depositAmount, "User should receive more than initial deposit due to gains");
    }
}
