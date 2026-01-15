// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC4626Strategy } from "./ERC4626Strategy.sol";
import { L1ReaderConstants } from "./L1ReaderConstants.sol";

interface IStrategy {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function assetBalanceOf() external view returns (uint256 balance);
}

interface IHLPStrategy {
    function hlpVault() external view returns (address);
}

contract MetaVault is ERC4626Strategy, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Allocation {
        address protocol;
        uint256 targetBps;
        bool isHLP;
    }

    struct WithdrawalRequest {
        address owner;
        uint256 requestId;
        uint256 shares;
        uint256 assets;
        uint256 requestTime;
    }

    struct WithdrawQueue {
        uint256 queuedWithdrawToFill;
        uint256 queuedWithdrawFilled;
    }

    struct WithdrawQueueStatus {
        bool queued;
        uint256 fillAt;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint256 public constant MAX_ALLOCATION_BPS = 6000;
    uint256 public constant WITHDRAWAL_DELAY = 5 days;

    Allocation[] public allocations;
    uint256 public withdrawalBufferTarget;
    uint256 public claimReserve;
    uint256 public withdrawRequestId;
    WithdrawQueue public withdrawQueue;
    mapping(bytes32 => WithdrawQueueStatus) public withdrawQueued;
    mapping(address => WithdrawalRequest[]) public withdrawRequests;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error AllocationExceedsLimit(uint256 allocationBps, uint256 maxBps);
    error InvalidTotalAllocation(uint256 totalBps);
    error InsufficientVaultLiquidity(uint256 requested, uint256 available);
    error InvalidWithdrawIndex();
    error WithdrawalTooEarly();
    error QueuedWithdrawalNotFilled();
    error InvalidAmount();
    error NoAllocations();
    error StrategyHasLockupPeriod();
    error NoStrategyAssets();
    error InsufficientInstantLiquidity();

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalQueued(
        address indexed owner,
        uint256 indexed requestId,
        uint256 shares,
        uint256 assets,
        bool queued,
        uint256 availableToWithdraw
    );
    event WithdrawalClaimed(address indexed owner, uint256 assets, uint256 requestId);
    event BufferFilled(uint256 amount, address indexed sender);
    event QueueFilled(uint256 amount, address indexed sender);

    /**
     * @notice Creates a new MetaVault
     * @dev Initializes the vault with the underlying asset and sets up roles
     * @param asset_ The underlying ERC20 asset this vault accepts
     * @param withdrawalBufferTarget_ The target buffer amount for instant withdrawals
     */
    constructor(IERC20 asset_, uint256 withdrawalBufferTarget_) ERC20("MetaVault", "mVault") ERC4626(asset_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        withdrawalBufferTarget = withdrawalBufferTarget_;
    }

    /*//////////////////////////////////////////////////////////////
                              READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total amount of underlying assets managed by the vault
     * @dev Aggregates assets from vault balance and all strategies (ERC4626 and non-ERC4626)
     * @return Total assets across vault and all strategies
     * @custom:category Read Function
     */
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < allocations.length; i++) {
            address strategy = allocations[i].protocol;
            if (!allocations[i].isHLP) {
                uint256 shares = IERC4626(strategy).balanceOf(address(this));
                if (shares > 0) {
                    total += IERC4626(strategy).convertToAssets(shares);
                }
            } else {
                // For HLP strategies, read balances directly from precompiles
                total += getHLPStrategyBalance(strategy);
            }
        }
        return total;
    }

    /**
     * @notice Get HLP strategy balance by reading directly from precompiles
     * @dev Reads vault balance, spot balance, perp balance, and contract balance
     * @param strategy The HLP strategy address
     * @return totalBalance Total balance from all sources
     * @custom:category Internal Function
     */
    function getHLPStrategyBalance(address strategy) public view returns (uint256 totalBalance) {
        // Get vault balance
        uint256 vaultBalance = getVaultBalance(strategy);
        
        // Get spot balance
        uint256 spotBalance = getSpotBalance(strategy);
        
        // Get perp balance
        uint256 perpBalance = getPerpBalance(strategy);
        
        // Get contract's own asset balance
        uint256 contractBalance = IERC20(asset()).balanceOf(strategy);
        
        totalBalance = vaultBalance + spotBalance + perpBalance + contractBalance;
    }

    /**
     * @notice Get vault equity balance directly from precompile
     * @param strategy The HLP strategy address
     * @return balance The vault equity balance
     * @custom:category Internal Function
     */
    function getVaultBalance(address strategy) public view returns (uint256 balance) {
        address hlpVault = IHLPStrategy(strategy).hlpVault();
        (bool success, bytes memory result) =
            L1ReaderConstants.VAULT_EQUITY_PRECOMPILE_ADDRESS.staticcall(abi.encode(strategy, hlpVault));

        if (success && result.length > 0) {
            (uint64 equity,) = abi.decode(result, (uint64, uint64));
            balance = uint256(equity);
        }
        // If read fails, return 0 (don't revert)
    }

    /**
     * @notice Get spot balance directly from precompile
     * @param strategy The HLP strategy address
     * @return balance The spot balance
     * @custom:category Internal Function
     */
    function getSpotBalance(address strategy) public view returns (uint256 balance) {
        (bool success, bytes memory result) = L1ReaderConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall(abi.encode(strategy, 0));
        if (success && result.length > 0) {
            (uint64 total,,) = abi.decode(result, (uint64, uint64, uint64));
            balance = uint256(total) / 1e2;
        }
        // If read fails, return 0 (don't revert)
    }

    /**
     * @notice Get perp balance directly from precompile
     * @param strategy The HLP strategy address
     * @return balance The perp balance (converted from int64 to uint256)
     * @custom:category Internal Function
     */
    function getPerpBalance(address strategy) public view returns (uint256 balance) {
        (bool success, bytes memory result) =
            L1ReaderConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS.staticcall(abi.encode(0, strategy));
        if (success && result.length > 0) {
            int64 accountValue = abi.decode(result, (int64));
            // Only add positive balances
            if (accountValue > 0) {
                balance = uint256(uint64(accountValue));
            }
        }
        // If read fails, return 0 (don't revert)
    }

    /**
     * @notice Returns the amount available for instant withdrawal
     * @dev Calculates vault balance minus claim reserve
     * @return Amount available for instant withdrawal
     * @custom:category Read Function
     */
    function getAvailableToWithdraw() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - claimReserve;
    }

    /**
     * @notice Returns the total withdrawal deficit (buffer deficit + queue deficit)
     * @dev Calculates how much needs to be filled for buffer and queue
     * @return Total deficit that needs to be filled
     * @custom:category Read Function
     */
    function getWithdrawDeficit() public view returns (uint256) {
        uint256 availableToWithdraw = getAvailableToWithdraw();
        uint256 bufferDeficit =
            withdrawalBufferTarget > availableToWithdraw ? withdrawalBufferTarget - availableToWithdraw : 0;
        uint256 queueDeficit = withdrawQueue.queuedWithdrawToFill > withdrawQueue.queuedWithdrawFilled
            ? withdrawQueue.queuedWithdrawToFill - withdrawQueue.queuedWithdrawFilled
            : 0;
        return bufferDeficit + queueDeficit;
    }

    /**
     * @notice Get user withdrawal requests with status and claimable times
     * @param user The user address to query
     * @return requestIds Array of request IDs (array indices)
     * @return amounts Array of asset amounts
     * @return statuses Array of statuses (0 = pending, 1 = ready)
     * @return endTimes Array of claimable timestamps
     * @custom:category Read Function
     */
    function getUserWithdrawalRequests(address user)
        external
        view
        returns (
            uint256[] memory requestIds,
            uint256[] memory amounts,
            uint8[] memory statuses,
            uint256[] memory endTimes
        )
    {
        WithdrawalRequest[] memory requests = withdrawRequests[user];
        uint256 count = requests.length;

        requestIds = new uint256[](count);
        amounts = new uint256[](count);
        statuses = new uint8[](count);
        endTimes = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            WithdrawalRequest memory request = requests[i];
            requestIds[i] = i;
            amounts[i] = request.assets;
            endTimes[i] = request.requestTime + WITHDRAWAL_DELAY;

            bytes32 withdrawHash = keccak256(abi.encode(request, user));
            bool isQueued =
                withdrawQueued[withdrawHash].queued
                && withdrawQueued[withdrawHash].fillAt > withdrawQueue.queuedWithdrawFilled;
            bool delayPassed = block.timestamp >= endTimes[i];

            if (!isQueued && delayPassed) {
                statuses[i] = 1;
            } else {
                statuses[i] = 0;
            }
        }

        return (requestIds, amounts, statuses, endTimes);
    }

    /*//////////////////////////////////////////////////////////////
                             WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit assets into the vault and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the minted shares
     * @return shares Amount of shares minted
     * @custom:category Write Function
     */
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares by depositing assets
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the minted shares
     * @return assets Amount of assets deposited
     * @custom:category Write Function
     */
    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256) {
        return super.mint(shares, receiver);
    }

    /**
     * @notice Redeem shares for underlying assets
     * @dev Handles both instant and queued withdrawals based on available liquidity
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets withdrawn
     * @custom:category Write Function
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        uint256 assets = previewRedeem(shares);
        uint256 availableInstant = _getTotalInstantLiquidity();
        uint256 instantAssets = assets > availableInstant ? availableInstant : assets;
        uint256 queuedAssets = assets - instantAssets;

        if (queuedAssets > 0) {
            uint256 queuedShares = convertToShares(queuedAssets);
            beforeWithdraw(queuedAssets, queuedShares);
        }

        if (instantAssets > 0) {
            _redeemInstantLiquidity(instantAssets);
            _withdraw(_msgSender(), receiver, owner, instantAssets, shares);
        }

        return assets;
    }

    /**
     * @notice Withdraw assets by burning shares
     * @dev Handles both instant and queued withdrawals based on available liquidity
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares
     * @return shares Amount of shares burned
     * @custom:category Write Function
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");

        uint256 shares = previewWithdraw(assets);
        uint256 availableInstant = _getTotalInstantLiquidity();
        uint256 instantAssets = assets > availableInstant ? availableInstant : assets;
        uint256 queuedAssets = assets - instantAssets;

        if (queuedAssets > 0) {
            uint256 queuedShares = convertToShares(queuedAssets);
            beforeWithdraw(queuedAssets, queuedShares);
        }

        if (instantAssets > 0) {
            _redeemInstantLiquidity(instantAssets);
            _withdraw(_msgSender(), receiver, owner, instantAssets, shares);
        }

        return shares;
    }

    /**
     * @notice Claims queued withdrawals after delay period
     * @dev Burns shares and transfers assets to user for claimable withdrawal requests
     * @param requestIndexes Array of request indexes to claim (must be in ascending order)
     * @custom:category Write Function
     */
    function claimWithdrawals(uint256[] calldata requestIndexes) external whenNotPaused nonReentrant {
        if (requestIndexes.length == 0) revert InvalidWithdrawIndex();

        address user = msg.sender;
        uint256 claimedAmount;
        uint256 totalShares;
        WithdrawalRequest[] storage requests = withdrawRequests[user];

        uint256 prevIndex = requestIndexes[0];
        if (prevIndex >= requests.length) revert InvalidWithdrawIndex();

        for (uint256 i = 1; i < requestIndexes.length;) {
            if (requestIndexes[i] <= prevIndex || requestIndexes[i] >= requests.length) revert InvalidWithdrawIndex();
            prevIndex = requestIndexes[i];
            unchecked {
                ++i;
            }
        }

        for (uint256 i = requestIndexes.length; i > 0;) {
            unchecked {
                --i;
            }
            uint256 index = requestIndexes[i];
            WithdrawalRequest storage request = requests[index];

            if (block.timestamp - request.requestTime < WITHDRAWAL_DELAY) {
                revert WithdrawalTooEarly();
            }

            bytes32 withdrawHash = keccak256(abi.encode(request, user));
            if (
                withdrawQueued[withdrawHash].queued
                    && withdrawQueued[withdrawHash].fillAt > withdrawQueue.queuedWithdrawFilled
            ) {
                revert QueuedWithdrawalNotFilled();
            }

            claimedAmount += request.assets;
            totalShares += request.shares;
            claimReserve -= request.assets;

            emit WithdrawalClaimed(user, request.assets, request.requestId);

            if (index != requests.length - 1) {
                requests[index] = requests[requests.length - 1];
            }
            requests.pop();
        }

        if (claimedAmount > 0) {
            _burn(address(this), totalShares);
            IERC20(asset()).safeTransfer(user, claimedAmount);
        }
    }

    /**
     * @notice External function for bots/strategies to fill the withdraw buffer and process queue
     * @dev Transfers assets from caller and fills buffer/queue deficit
     * @param amount The amount of assets to transfer and use for filling buffer
     * @custom:category Write Function
     */
    function fillWithdrawalBuffer(uint256 amount) public nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        uint256 queueDeficit = withdrawQueue.queuedWithdrawToFill > withdrawQueue.queuedWithdrawFilled
            ? withdrawQueue.queuedWithdrawToFill - withdrawQueue.queuedWithdrawFilled
            : 0;

        uint256 queueFilled = 0;
        if (queueDeficit > 0) {
            queueFilled = queueDeficit > amount ? amount : queueDeficit;
            claimReserve += queueFilled;
            withdrawQueue.queuedWithdrawFilled += queueFilled;
            emit QueueFilled(queueFilled, msg.sender);
        }

        uint256 bufferFilled = amount - queueFilled;
        if (bufferFilled > 0) {
            emit BufferFilled(bufferFilled, msg.sender);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Hook called after deposit to distribute assets to strategies
     * @dev First fills buffer/queue deficit, then distributes remaining to strategies
     * @param assets The amount of assets that were deposited
     * @custom:category Internal Function
     */
    function afterDeposit(
        uint256 assets,
        uint256 /* shares */
    )
        internal
        override
    {
        uint256 amountToFill = 0;

        // Check if any strategy has lockup period
        // If all strategies are instant (no lockup), skip deficit filling
        // Buffer is only needed when there are strategies with lockup periods
        bool hasHLPStrategy = false;
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].isHLP) {
                hasHLPStrategy = true;
                break;
            }
        }

        // Only fill deficit if there are strategies with lockup periods
        if (hasHLPStrategy) {
            uint256 deficit = getWithdrawDeficit();
            if (deficit > 0) {
                amountToFill = deficit > assets ? assets : deficit;
                _fillBuffer(amountToFill);
            }
        }

        uint256 remainingAssets = assets - amountToFill;
        if (remainingAssets > 0 && allocations.length > 0) {
            _distributeToStrategies(remainingAssets);
        }
    }

    /**
     * @notice Get total instant liquidity from all strategies without lockup
     * @dev Only checks ERC4626 strategies (instant liquidity strategies)
     * @return totalInstant Total instant liquidity available
     * @custom:category Internal Function
     */
    function _getTotalInstantLiquidity() internal view returns (uint256 totalInstant) {
        for (uint256 i = 0; i < allocations.length; i++) {
            if (!allocations[i].isHLP) {
                address strategy = allocations[i].protocol;
                uint256 shares = IERC4626(strategy).balanceOf(address(this));
                if (shares > 0) {
                    totalInstant += IERC4626(strategy).convertToAssets(shares);
                }
            }
        }
        return totalInstant;
    }

    /**
     * @notice Hook called before withdrawal to handle queued portion
     * @dev Queues withdrawal request for strategies with lockup periods
     * @param assets The queued amount of assets to be queued
     * @param shares The queued amount of shares to be queued
     * @custom:category Internal Function
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        _queueWithdrawal(msg.sender, shares, assets);
    }

    /**
     * @notice Redeem instant liquidity from strategies without lockup period
     * @dev Only processes ERC4626 strategies that have isHLP = false
     * @param assets The amount of assets to redeem
     * @custom:category Internal Function
     */
    function _redeemInstantLiquidity(uint256 assets) internal {
        uint256 remainingNeeded = assets;
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].isHLP) {
                continue;
            }

            address strategy = allocations[i].protocol;
            uint256 shares = IERC4626(strategy).balanceOf(address(this));

            if (shares > 0) {
                uint256 assetsAvailable = IERC4626(strategy).convertToAssets(shares);
                uint256 assetsToRedeem = assetsAvailable > remainingNeeded ? remainingNeeded : assetsAvailable;

                if (assetsToRedeem > 0) {
                    // Use withdraw to get exact assets amount (takes assets, returns shares)
                    // withdraw() returns shares burned, but we track assets
                    IERC4626(strategy).withdraw(assetsToRedeem, address(this), address(this));
                    remainingNeeded -= assetsToRedeem;

                    if (remainingNeeded == 0) break;
                }
            }
        }

        if (remainingNeeded != 0) {
            revert InsufficientInstantLiquidity();
        }
    }

    /**
     * @notice Queue a withdrawal request
     * @dev Transfers shares from owner to contract for later burning at claim time
     * @param owner The owner of the shares
     * @param shares The shares to be burned at claim time
     * @param assets The assets to be withdrawn
     * @custom:category Internal Function
     */
    function _queueWithdrawal(address owner, uint256 shares, uint256 assets) internal {
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _transfer(owner, address(this), shares);
        withdrawRequestId++;

        WithdrawalRequest memory request = WithdrawalRequest({
            owner: owner, requestId: withdrawRequestId, shares: shares, assets: assets, requestTime: block.timestamp
        });

        withdrawRequests[owner].push(request);

        uint256 availableToWithdraw = getAvailableToWithdraw();
        bool queued = false;

        if (assets > availableToWithdraw) {
            claimReserve += availableToWithdraw;
            withdrawQueue.queuedWithdrawFilled += availableToWithdraw;
            withdrawQueue.queuedWithdrawToFill += assets;

            bytes32 withdrawHash = keccak256(abi.encode(request, owner));
            withdrawQueued[withdrawHash].queued = true;
            withdrawQueued[withdrawHash].fillAt = withdrawQueue.queuedWithdrawToFill;
            queued = true;
        } else {
            claimReserve += assets;
        }

        emit WithdrawalQueued(owner, withdrawRequestId, shares, assets, queued, availableToWithdraw);
    }

    /**
     * @notice Distribute assets to strategies based on allocations
     * @dev Distributes assets proportionally according to targetBps
     * @param totalAmount The total amount of assets to distribute
     * @custom:category Internal Function
     */
    function _distributeToStrategies(uint256 totalAmount) internal {
        IERC20 assetToken = IERC20(asset());

        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 strategyAmount = (totalAmount * allocations[i].targetBps) / 10_000;

            if (strategyAmount > 0) {
                address strategy = allocations[i].protocol;
                SafeERC20.forceApprove(assetToken, strategy, strategyAmount);
                IStrategy(strategy).deposit(strategyAmount, address(this));
                SafeERC20.forceApprove(assetToken, strategy, 0);
            }
        }
    }

    /**
     * @notice Fill buffer with specified amount
     * @dev Handles queue deficit first, then fills buffer target
     * @param amount The amount to use for filling buffer/queue
     * @custom:category Internal Function
     */
    function _fillBuffer(uint256 amount) internal {
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 queueDeficit = withdrawQueue.queuedWithdrawToFill > withdrawQueue.queuedWithdrawFilled
            ? withdrawQueue.queuedWithdrawToFill - withdrawQueue.queuedWithdrawFilled
            : 0;

        uint256 queueFilled = 0;
        if (queueDeficit > 0) {
            queueFilled = queueDeficit > amount ? amount : queueDeficit;
            claimReserve += queueFilled;
            withdrawQueue.queuedWithdrawFilled += queueFilled;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the target allocations for protocol strategies
     * @dev Each allocation's targetBps must not exceed MAX_ALLOCATION_BPS (50%)
     * @dev Total allocations must equal 10000 bps (100%)
     * @param allocations_ Array of Allocation structs containing protocol addresses, target basis points, and lockup
     * flag
     * @custom:category Admin Function
     */
    function setAllocations(Allocation[] calldata allocations_) external onlyRole(MANAGER_ROLE) whenNotPaused {
        delete allocations;

        uint256 totalBps = 0;

        for (uint256 i = 0; i < allocations_.length; i++) {
            if (allocations_[i].targetBps > MAX_ALLOCATION_BPS) {
                revert AllocationExceedsLimit(allocations_[i].targetBps, MAX_ALLOCATION_BPS);
            }
            totalBps += allocations_[i].targetBps;
            allocations.push(allocations_[i]);
        }

        if (totalBps != 10_000) {
            revert InvalidTotalAllocation(totalBps);
        }
    }

    /**
     * @notice Rebalances the vault's assets to match target allocations
     * @dev Only rebalances if ALL strategies have no lockup periods (all are ERC4626)
     * @dev Withdraws excess from over-allocated strategies and deposits to under-allocated strategies
     * @custom:category Admin Function
     */
    function rebalance() external onlyRole(MANAGER_ROLE) whenNotPaused {
        if (allocations.length == 0) {
            revert NoAllocations();
        }

        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].isHLP) {
                revert StrategyHasLockupPeriod();
            }
        }

        uint256 totalStrategyAssets = 0;
        uint256[] memory strategyAssets = new uint256[](allocations.length);

        for (uint256 i = 0; i < allocations.length; i++) {
            address strategy = allocations[i].protocol;
            uint256 shares = IERC4626(strategy).balanceOf(address(this));

            if (shares > 0) {
                uint256 assets = IERC4626(strategy).convertToAssets(shares);
                strategyAssets[i] = assets;
                totalStrategyAssets += assets;
            }
        }

        if (totalStrategyAssets == 0) {
            revert NoStrategyAssets();
        }

        IERC20 assetToken = IERC20(asset());

        // Step 1: Withdraw excess from over-allocated strategies
        // Example: Strategy A has 70, Strategy B has 110, total = 180
        // Target for each (50%): 90
        // Withdraw 20 from B (110 -> 90)
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 targetAssets = (totalStrategyAssets * allocations[i].targetBps) / 10_000;
            uint256 currentAssets = strategyAssets[i];

            if (currentAssets > targetAssets) {
                // Strategy is over-allocated: withdraw excess
                uint256 excess = currentAssets - targetAssets;

                if (excess > 0) {
                    address strategy = allocations[i].protocol;
                    uint256 sharesToRedeem = IERC4626(strategy).previewRedeem(excess);

                    if (sharesToRedeem > 0) {
                        IERC4626(strategy).redeem(sharesToRedeem, address(this), address(this));
                    }
                }
            }
        }

        // Step 2: Deposit to under-allocated strategies
        // Example: Deposit 20 to A (70 -> 90) so both become 90-90
        // Get available balance from vault (withdrawn assets from over-allocated strategies)
        // Note: claimReserve is not needed here since all strategies are instant (no lockup period)
        uint256 availableBalance = IERC20(asset()).balanceOf(address(this));

        if (availableBalance > 0) {
            // Recalculate current assets after withdrawals
            uint256 newTotalStrategyAssets = 0;
            uint256[] memory newStrategyAssets = new uint256[](allocations.length);

            for (uint256 i = 0; i < allocations.length; i++) {
                address strategy = allocations[i].protocol;
                uint256 shares = IERC4626(strategy).balanceOf(address(this));
                if (shares > 0) {
                    uint256 assets = IERC4626(strategy).convertToAssets(shares);
                    newStrategyAssets[i] = assets;
                    newTotalStrategyAssets += assets;
                }
            }

            // Add available balance to total (will be deposited)
            newTotalStrategyAssets += availableBalance;

            // Deposit to under-allocated strategies
            for (uint256 i = 0; i < allocations.length; i++) {
                uint256 targetAssets = (newTotalStrategyAssets * allocations[i].targetBps) / 10_000;
                uint256 currentAssets = newStrategyAssets[i];

                if (currentAssets < targetAssets) {
                    uint256 deficit = targetAssets - currentAssets;
                    uint256 depositAmount = deficit > availableBalance ? availableBalance : deficit;

                    if (depositAmount > 0) {
                        address strategy = allocations[i].protocol;
                        SafeERC20.forceApprove(assetToken, strategy, depositAmount);
                        IERC4626(strategy).deposit(depositAmount, address(this));
                        SafeERC20.forceApprove(assetToken, strategy, 0);

                        availableBalance -= depositAmount;
                        if (availableBalance == 0) break;
                    }
                }
            }
        }
    }

    /**
     * @notice Updates the withdrawal buffer target
     * @param newTarget The new target buffer amount
     * @custom:category Admin Function
     */
    function updateWithdrawalBufferTarget(uint256 newTarget) external onlyRole(MANAGER_ROLE) {
        withdrawalBufferTarget = newTarget;
    }

    /**
     * @notice Pauses the contract, preventing deposits, withdrawals, and rebalancing
     * @custom:category Admin Function
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing normal operations to resume
     * @custom:category Admin Function
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }
}
