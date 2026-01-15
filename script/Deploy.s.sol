// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { MockInstantStrategy } from "../src/Mock/MockInstantStrategy.sol";
import { HLPStrategy } from "../src/HLPStrategy.sol";
import { MetaVault } from "../src/MetaVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // TODO: Fill in these addresses/values
        // ============================================

        // Asset token address (e.g., USDC on HyperEVM testnet)
        address assetAddress = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

        // ============================================
        // 1. Deploy MockInstantStrategy
        // ============================================
        console.log("\n=== Deploying MockInstantStrategy ===");

        // TODO: Fill in constructor arguments
        // MockInstantStrategy constructor: (IERC20 asset_, uint256 interestRate_, string memory name_, string memory
        // symbol_)
        IERC20 asset = IERC20(assetAddress);
        uint256 interestRate = 5; // Default 5% (500 bps)
        string memory mockName = "MockInstantStrategy";
        string memory mockSymbol = "MOCK";

        MockInstantStrategy mockStrategy = new MockInstantStrategy(asset, interestRate, mockName, mockSymbol);

        console.log("MockInstantStrategy deployed at:", address(mockStrategy));

        // ============================================
        // 2. Deploy MetaVault (deploy first so we can use its address for HLPStrategy)
        // ============================================
        console.log("\n=== Deploying MetaVault ===");

        // TODO: Fill in constructor arguments
        // MetaVault constructor: (IERC20 asset_, uint256 withdrawalBufferTarget_)
        uint256 withdrawalBufferTarget = 0;

        MetaVault metaVault = new MetaVault(asset, withdrawalBufferTarget);

        console.log("MetaVault deployed at:", address(metaVault));

        // ============================================
        // 3. Deploy HLPStrategy (with MetaVault address)
        // ============================================
        console.log("\n=== Deploying HLPStrategy ===");

        // TODO: Fill in constructor arguments
        // HLPStrategy constructor: (IERC20 asset_, address hlpVault_, address metaVault_)

        address hlpVault = 0xdfc24b077bc1425AD1DEA75bCB6f8158E10Df303;
        address coreDepositWallet = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
        HLPStrategy hlpStrategy = new HLPStrategy(
            asset,
            address(metaVault),
            address(hlpVault),
            address(coreDepositWallet)
        );

        console.log("HLPStrategy deployed at:", address(hlpStrategy));

        // ============================================
        // 4. Set Allocations in MetaVault
        // ============================================
        console.log("\n=== Setting Allocations in MetaVault ===");

        // Allocation percentages (in basis points, must total 10000 = 100%)
        // TODO: Adjust these percentages as needed
        uint256 instantStrategyBps = 4000; // Default 40%
        uint256 hlpStrategyBps = 6000; // Default 60%

        // Ensure total is 10000 (100%)
        require(instantStrategyBps + hlpStrategyBps == 10_000, "Allocations must total 10000 bps (100%)");

        MetaVault.Allocation[] memory allocations = new MetaVault.Allocation[](2);

        // First strategy: MockInstantStrategy (isHLP = false)
        allocations[0] = MetaVault.Allocation({
            protocol: address(mockStrategy), targetBps: instantStrategyBps, isHLP: false
        });

        // Second strategy: HLPStrategy (isHLP = true)
        allocations[1] =
            MetaVault.Allocation({ protocol: address(hlpStrategy), targetBps: hlpStrategyBps, isHLP: true });

        metaVault.setAllocations(allocations);

        console.log("Allocations set:");
        // ============================================
        // Summary
        // ============================================
        console.log("\n=== Deployment Summary ===");
        console.log("MockInstantStrategy:", address(mockStrategy));
        console.log("MetaVault:", address(metaVault));
        console.log("HLPStrategy:", address(hlpStrategy));
        console.log("\nAllocations configured:");
        console.log("  Strategy 1 (MockInstantStrategy):", instantStrategyBps, "bps");
        console.log("  Strategy 2 (HLPStrategy):", hlpStrategyBps, "bps");
        console.log("\nDeployment completed successfully!");

        vm.stopBroadcast();
    }
}
