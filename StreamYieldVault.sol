// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/extensions/ERC4626.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";

import "./interfaces/IStrategy.sol";

/// @title StreamYield Vault (ERC4626 + principal protection + yield-only spending)
contract StreamYieldVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice User principal tracking: deposit increases it, normal withdraw decreases it.
    mapping(address => uint256) public principalAssets;

    /// @notice SubscriptionManager contract that can redeem yield-only for users.
    address public subscriptionManager;

    /// @notice Strategy (Aave V3) that manages assets.
    IStrategy public strategy;

    event SubscriptionManagerSet(address indexed manager);
    event StrategySet(address indexed strategy);
    event PushedToStrategy(uint256 amount);
    event PulledFromStrategy(uint256 amount);
    event YieldWithdrawn(address indexed user, address indexed to, uint256 assets);

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_) 
        ERC4626(asset_) 
        Ownable(msg.sender)
    {}

    /* -------------------------------------------------------------------------- */
    /*                            ADMIN CONFIG                                    */
    /* -------------------------------------------------------------------------- */

    function setSubscriptionManager(address mgr) external onlyOwner {
        subscriptionManager = mgr;
        emit SubscriptionManagerSet(mgr);
    }

    function setStrategy(address _strategy) external onlyOwner {
        strategy = IStrategy(_strategy);
        emit StrategySet(_strategy);
    }

    /* -------------------------------------------------------------------------- */
    /*                          PRINCIPAL ACCOUNTING                              */
    /* -------------------------------------------------------------------------- */

    function _afterDeposit(address caller, address receiver, uint256 assets, uint256 /*shares*/) internal {
        // Owner deposits should not affect principal tracking (optional).
        if (caller != owner()) {
            principalAssets[receiver] += assets;
        }
    }

    function deposit(uint256 assets, address receiver)
        public 
        override 
        nonReentrant 
        returns (uint256 shares) 
    {
        shares = super.deposit(assets, receiver);
        _afterDeposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver)
        public 
        override 
        nonReentrant 
        returns (uint256 assets) 
    {
        assets = super.mint(shares, receiver);
        _afterDeposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public 
        override 
        nonReentrant 
        returns (uint256 shares) 
    {
        shares = super.withdraw(assets, receiver, owner_);
        _reducePrincipal(owner_, assets);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public 
        override 
        nonReentrant 
        returns (uint256 assets) 
    {
        assets = super.redeem(shares, receiver, owner_);
        _reducePrincipal(owner_, assets);
    }

    function _reducePrincipal(address user, uint256 assetsReduced) internal {
        uint256 p = principalAssets[user];
        principalAssets[user] = assetsReduced >= p ? 0 : p - assetsReduced;
    }

    /* -------------------------------------------------------------------------- */
    /*                           STRATEGY INTEGRATION                             */
    /* -------------------------------------------------------------------------- */

    /// @notice Before withdraw: if idle liquidity is not enough, pull from strategy.
function _beforeWithdraw(
    address /*caller*/,
    address /*receiver*/,
    address /*owner*/,
    uint256 assets,
    uint256 /*shares*/
) internal {  // <-- Remove `override`
    uint256 idle = IERC20(asset()).balanceOf(address(this));
    if (idle < assets && address(strategy) != address(0)) {
        strategy.freeFunds(assets - idle);
    }
}
    /// @notice Move assets from vault to strategy and deploy them.
    function pushToStrategy(uint256 amount) external onlyOwner {
        require(address(strategy) != address(0), "strategy not set");

        IERC20(asset()).safeTransfer(address(strategy), amount);
        strategy.deployFunds(amount);

        emit PushedToStrategy(amount);
    }

    /// @notice Pull funds back from strategy (increase idle assets).
    function pullFromStrategy(uint256 amount) external onlyOwner {
        require(address(strategy) != address(0), "strategy not set");
        strategy.freeFunds(amount);
        emit PulledFromStrategy(amount);
    }

    /// @notice totalAssets() = idle tokens + strategy-managed tokens
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 strat = address(strategy) == address(0) ? 0 : strategy.totalManagedAssets();
        return idle + strat;
    }

    /* -------------------------------------------------------------------------- */
    /*                               YIELD LOGIC                                  */
    /* -------------------------------------------------------------------------- */

    /// @notice User's total value = convert shares → assets
    function userAssets(address user) public view returns (uint256) {
        return convertToAssets(balanceOf(user));
    }

    /// @notice Yield = user assets − principal
    function availableYield(address user) public view returns (uint256) {
        uint256 assetsNow = userAssets(user);
        uint256 p = principalAssets[user];
        return assetsNow > p ? (assetsNow - p) : 0;
    }

    /// @notice Spend ONLY yield for subscription payments
    function withdrawYieldFor(address user, address to, uint256 assets)
        external 
        nonReentrant 
        returns (uint256 paid)
    {
        require(msg.sender == subscriptionManager, "not subscription manager");

        uint256 maxAvail = availableYield(user);
        paid = assets > maxAvail ? maxAvail : assets;

        if (paid == 0) return 0;

        uint256 shares = convertToShares(paid);

        // Manager must have allowance of user's shares
        _spendAllowance(user, msg.sender, shares);

        super.redeem(shares, to, user);

        emit YieldWithdrawn(user, to, paid);
    }
}
