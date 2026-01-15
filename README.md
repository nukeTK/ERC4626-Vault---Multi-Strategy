# MetaVault - Multi-Strategy Yield Aggregator

A sophisticated ERC-4626 compliant vault system that aggregates yield across multiple DeFi strategies while providing instant withdrawals through a buffer mechanism and queued withdrawals for strategies with lockup periods.

## Overview

MetaVault is a yield aggregator that allows users to deposit assets (USDC) and automatically allocates them across multiple yield-generating strategies. The vault implements a dual-withdrawal system:

1. **Instant Withdrawals**: Available when sufficient liquidity exists in the vault buffer
2. **Queued Withdrawals**: For larger withdrawals or when buffer is insufficient, withdrawals are queued with a 5-day delay before they can be claimed

The vault intelligently manages asset allocation across different strategies, tracks balances from both ERC-4626 compliant strategies and custom HLP (Hyperliquid) strategies, and maintains a withdrawal buffer to ensure liquidity for instant withdrawals.

## Architecture

### Core Components

1. **MetaVault** - Main vault contract implementing ERC-4626 standard
2. **Strategy Contracts** - Individual yield-generating strategies:
   - **MockInstantStrategy** - Mock strategy for testing with instant withdrawals
   - **HLPStrategy** - Strategy for Hyperliquid HLP vault integration

### Key Features

- **Multi-Strategy Allocation**: Distributes assets across multiple strategies based on configurable target allocations (basis points)
- **Dual Withdrawal System**: 
  - Instant withdrawals when buffer has sufficient liquidity
  - Queued withdrawals with 5-day delay for larger amounts or when buffer is insufficient
- **Buffer Management**: Maintains a target buffer amount for instant withdrawals
- **Strategy Balance Tracking**: Supports both ERC-4626 strategies and custom HLP strategies with direct precompile reading
- **Access Control**: Role-based access control with MANAGER_ROLE and EMERGENCY_ROLE
- **Pausable**: Emergency pause functionality for security

## Deployed Contracts

### Mainnet Deployment (HyperEVM)

| Contract | Address | Explorer |
|----------|---------|----------|
| **MetaVault** | [`0x3689fA7E06314C70767f8455eF5b250532164868`](https://hyperevmscan.io/address/0x3689fA7E06314C70767f8455eF5b250532164868#code) | [View on HyperEVMScan](https://hyperevmscan.io/address/0x3689fA7E06314C70767f8455eF5b250532164868#code) |
| **MockInstantStrategy** | [`0x461150E585A67397DF3319BFF0F46197E0a5aE2C`](https://hyperevmscan.io/address/0x461150E585A67397DF3319BFF0F46197E0a5aE2C#code) | [View on HyperEVMScan](https://hyperevmscan.io/address/0x461150E585A67397DF3319BFF0F46197E0a5aE2C#code) |
| **HLPStrategy** | [`0x9781a74D60E7921fF349E19C20D0101Ca7087Ee0`](https://hyperevmscan.io/address/0x9781a74D60E7921fF349E19C20D0101Ca7087Ee0#code) | [View on HyperEVMScan](https://hyperevmscan.io/address/0x9781a74D60E7921fF349E19C20D0101Ca7087Ee0#code) |

### Deployment Summary

```
=== Deployment Summary ===
  MockInstantStrategy: 0x461150E585A67397DF3319BFF0F46197E0a5aE2C
  MetaVault: 0x3689fA7E06314C70767f8455eF5b250532164868
  HLPStrategy: 0x9781a74D60E7921fF349E19C20D0101Ca7087Ee0
  
Allocations configured:
    Strategy 1 (MockInstantStrategy): 4000 bps (40%)
    Strategy 2 (HLPStrategy): 6000 bps (60%)
```

## How It Works

### Deposit Flow

1. User deposits USDC to MetaVault
2. MetaVault mints vault shares (ERC-20 tokens) to the user
3. Assets are automatically distributed to strategies based on target allocations:
   - 40% to MockInstantStrategy
   - 60% to HLPStrategy
4. Strategies generate yield on deposited assets

### Withdrawal Flow

#### Instant Withdrawal
1. User requests withdrawal
2. If buffer has sufficient liquidity, withdrawal is processed immediately
3. User receives assets and vault shares are burned

#### Queued Withdrawal
1. User requests withdrawal larger than available buffer
2. Withdrawal is queued with a 5-day delay
3. After 5 days, user can claim the withdrawal
4. Assets are withdrawn from strategies to fulfill the queue
5. User receives assets and vault shares are burned

### Strategy Allocation

The vault distributes assets to strategies proportionally based on `targetBps` (target basis points):

- **Basis Points (bps)**: 1 bps = 0.01%, 100 bps = 1%, 10,000 bps = 100%
- **Current Allocation**:
  - MockInstantStrategy: 4,000 bps (40%)
  - HLPStrategy: 6,000 bps (60%)
- **Maximum per Strategy**: 6,000 bps (60%) - enforced by `MAX_ALLOCATION_BPS`
- **Total Allocation**: Must equal 10,000 bps (100%)

### Buffer Management

The vault maintains a withdrawal buffer to enable instant withdrawals:

- **Buffer Target**: Configurable target amount for instant withdrawals
- **Buffer Deficit**: When buffer is below target, strategies can fill it
- **Queue Deficit**: Amount needed to fulfill queued withdrawals
- **Fill Buffer**: Managers can call `fillWithdrawalBuffer()` to withdraw from strategies and fill the buffer

## Contract Details

### MetaVault

**Key Functions:**
- `deposit(uint256 assets, address receiver)` - Deposit assets and receive vault shares
- `withdraw(uint256 assets, address receiver, address owner)` - Withdraw assets (instant or queued)
- `redeem(uint256 shares, address receiver, address owner)` - Redeem shares for assets
- `queueWithdrawal(uint256 shares, address receiver)` - Queue a withdrawal request
- `claimWithdrawal(uint256 requestIndex)` - Claim a queued withdrawal after delay
- `fillWithdrawalBuffer(uint256 amount)` - Fill withdrawal buffer from strategies
- `setAllocations(Allocation[] allocations_)` - Update strategy allocations (manager only)
- `pause()` / `unpause()` - Emergency pause functionality (emergency role only)

**Key State Variables:**
- `withdrawalBufferTarget` - Target buffer amount for instant withdrawals
- `WITHDRAWAL_DELAY` - 5 days delay for queued withdrawals
- `MAX_ALLOCATION_BPS` - Maximum 60% allocation per strategy

### MockInstantStrategy

A mock ERC-4626 strategy for testing purposes that:
- Accepts deposits and mints shares
- Allows instant withdrawals (no lockup period)
- Charges a configurable interest rate (currently 5 bps = 0.05%)
- Implements pause functionality for emergency stops

**Contract**: [`0x461150E585A67397DF3319BFF0F46197E0a5aE2C`](https://hyperevmscan.io/address/0x461150E585A67397DF3319BFF0F46197E0a5aE2C#code)

### HLPStrategy

A strategy that integrates with Hyperliquid's HLP (Hyperliquid Liquidity Provider) vault:
- Deposits assets to Hyperliquid L1 vault via CoreWriter
- Tracks balances from multiple sources (vault, spot, perp, contract balance)
- Uses precompiles to read balances directly from Hyperliquid
- Can fill MetaVault's withdrawal buffer when needed

**Contract**: [`0x9781a74D60E7921fF349E19C20D0101Ca7087Ee0`](https://hyperevmscan.io/address/0x9781a74D60E7921fF349E19C20D0101Ca7087Ee0#code)

## Security Features

- **Access Control**: Role-based permissions (DEFAULT_ADMIN_ROLE, MANAGER_ROLE, EMERGENCY_ROLE)
- **Reentrancy Protection**: ReentrancyGuard on all state-changing functions
- **Pausable**: Emergency pause mechanism for security incidents
- **Safe Math**: OpenZeppelin's SafeERC20 for token operations
- **Allocation Limits**: Maximum 60% allocation per strategy to prevent over-concentration
- **Withdrawal Delay**: 5-day delay on queued withdrawals to prevent bank runs

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (for dependencies)

### Setup

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Format code
forge fmt

# Generate gas snapshots
forge snapshot
```

### Testing

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/MetaVault.t.sol

# Run with verbosity
forge test -vvv
```

### Deployment

```bash
# Deploy to HyperEVM
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $HYPER_EVM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

## Network Information

- **Network**: HyperEVM (Hyperliquid EVM)
- **Chain ID**: Check [HyperEVMScan](https://hyperevmscan.io) for current chain ID
- **Block Explorer**: [HyperEVMScan](https://hyperevmscan.io)
- **Asset**: USDC (USD Coin)

## License

MIT

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
