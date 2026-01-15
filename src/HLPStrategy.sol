// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMetaVault {
    function fillWithdrawalBuffer(uint256 amount) external;
}

interface ICoreWriter {
    function sendRawAction(bytes memory data) external;
}

interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
}

contract HLPStrategy is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    ICoreWriter public constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);
    address public constant USDC_SYSTEM_ADDRESS = 0x2000000000000000000000000000000000000000;
    uint64 public constant USDC_TOKEN_ID = 0;
    uint32 public constant EXTERNAL_DEX_ID = 4294967295;

    IERC20 public immutable asset;
    address public hlpVault;
    address public immutable metaVault;
    address public coreDepositWallet;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAmount();
    error InvalidTokenId();
    error InvalidAsset();
    error InvalidVault();
    error NotMetaVault();

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositToL1(uint256 amount);
    event DepositToVault(address indexed vault, uint256 amount);
    event USDTransferred(uint64 ntl, bool toPerp);
    event SpotBalanceSent(address indexed destination, uint64 tokenId, uint64 amount);
    event BufferFilled(uint256 amount, address indexed sender);

    modifier onlyMetaVault() {
        if (msg.sender != metaVault) revert NotMetaVault();
        _;
    }

    /**
     * @notice Creates a new HLPStrategy
     * @dev Initializes the strategy with asset, vault, and MetaVault addresses
     * @param asset_ The underlying ERC20 asset (typically USDC)
     * @param metaVault_ The MetaVault address
     */
    constructor(IERC20 asset_, address metaVault_, address hlpVault_, address coreDepositWallet_) {
        if (address(asset_) == address(0)) revert InvalidAsset();
        if (metaVault_ == address(0)) revert InvalidVault();

        asset = asset_;
        metaVault = metaVault_;
        hlpVault = hlpVault_;
        coreDepositWallet = coreDepositWallet_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                             WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets to the HLP vault via CoreWriter
     * @dev Uses action 0x02 (VAULT_TRANSFER) to deposit to the vault
     * @param assets The amount of assets to deposit (in wei precision, 18 decimals)
     * @return shares Amount of shares minted (always returns assets for compatibility)
     * @custom:category Write Function
     */
    function deposit(
        uint256 assets,
        address /*receiver*/
    )
        public
        onlyMetaVault
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();

        SafeERC20.safeTransferFrom(asset, msg.sender, address(this), assets);

        asset.forceApprove(coreDepositWallet, assets);
        ICoreDepositWallet(coreDepositWallet).deposit(assets, EXTERNAL_DEX_ID);
        asset.forceApprove(coreDepositWallet, 0);

        emit DepositToL1(assets);
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer USD between perp and spot accounts
     * @dev Uses CoreWriter action 7. If toPerp is false, transfers FROM perp TO spot
     * @param ntl Amount in HyperCore 1e6 precision (uint64)
     * @param toPerp If true, transfer to perp account; if false, transfer to spot (from perp)
     * @custom:category Admin Function
     */
    function transferUSDToPerpOrSpot(uint64 ntl, bool toPerp) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (ntl == 0) revert InvalidAmount();

        bytes memory params = abi.encode(ntl, toPerp);
        _sendRawAction(0x07, params);

        emit USDTransferred(ntl, toPerp);
    }

    /**
     * @notice Send tokens from spot balance to destination
     * @dev Uses CoreWriter action 6. Sends USDC (tokenId 0) from spot balance to USDC system address
     * @param amount Amount in HyperCore precision (uint64) to send
     * @custom:category Admin Function
     */
    function sendSpotBalanceToDestination(uint64 amount) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (amount == 0) revert InvalidAmount();

        address destination = USDC_SYSTEM_ADDRESS;
        uint64 tokenId = USDC_TOKEN_ID;

        bytes memory params = abi.encode(destination, tokenId, amount);
        _sendRawAction(0x06, params);

        emit SpotBalanceSent(destination, tokenId, amount);
    }

    /**
     * @notice Deposit or withdraw USD to/from the vault
     * @dev Uses action 0x02 (VAULT_TRANSFER) to deposit or withdraw from the vault
     * @param amount The amount of assets to deposit/withdraw (in wei precision, 18 decimals)
     * @param isDeposit If true, deposit to vault; if false, withdraw from vault
     * @custom:category Admin Function
     */
    function depositOrWithdrawUSDVault(uint256 amount, bool isDeposit)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        if (amount == 0) revert InvalidAmount();

        uint64 usdAmount = uint64(amount);
        bytes memory params = abi.encode(hlpVault, isDeposit, usdAmount);
        _sendRawAction(0x02, params);

        emit DepositToVault(hlpVault, amount);
    }

    /**
     * @notice Withdraw from HyperCore vault and fill MetaVault's withdrawal buffer
     * @dev Withdraws USDC from HyperCore vault and transfers to MetaVault to fill buffer
     * @param amount The amount of assets to withdraw from vault and transfer to MetaVault
     * @custom:category Admin Function
     */
    function fillMetaVaultBuffer(uint256 amount) external nonReentrant whenNotPaused onlyRole(MANAGER_ROLE) {
        if (amount == 0) revert InvalidAmount();
        IMetaVault(metaVault).fillWithdrawalBuffer(amount);
        emit BufferFilled(amount, msg.sender);
    }

    /**
     * @notice Pauses the contract, preventing deposits and transfers
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

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper function to send raw action to CoreWriter
     * @dev Encodes action data and sends to CoreWriter system contract
     * @param actionId The action ID (0x02 for VAULT_TRANSFER, 0x06 for SPOT_SEND, 0x07 for USD_TRANSFER)
     * @param params The encoded parameters for the action
     * @custom:category Internal Function
     */
    function _sendRawAction(uint8 actionId, bytes memory params) internal {
        bytes memory data = new bytes(4 + params.length);

        data[0] = 0x01;
        data[1] = 0x00;
        data[2] = 0x00;
        data[3] = bytes1(actionId);

        for (uint256 i = 0; i < params.length; i++) {
            data[4 + i] = params[i];
        }

        CORE_WRITER.sendRawAction(data);
    }
}
