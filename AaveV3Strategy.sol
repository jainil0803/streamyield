// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAaveV3.sol";
import "./interfaces/IStrategy.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";

/// @title AaveV3 Strategy for StreamYield
/// @notice StreamYieldVault sends funds here → strategy supplies into Aave V3 → yield accumulates automatically.
contract AaveV3Strategy is IStrategy, Ownable {
    IERC20 public immutable asset;     // USDC, DAI, etc
    IPool  public immutable pool;      // Aave V3 Pool contract
    IAToken public immutable aToken;   // Interest-bearing aToken
    address public immutable vault;    // StreamYieldVault address

    modifier onlyVault() {
        require(msg.sender == vault, "caller is not vault");
        _;
    }

    constructor(
        IERC20 _asset,
        IPool _pool,
        IAToken _aToken,
        address _vault,
        address initialOwner
    )
        Ownable(initialOwner)   // ✅ FIX: Call OZ Ownable constructor properly
    {
        asset = _asset;
        pool = _pool;
        aToken = _aToken;
        vault = _vault;
    }

    /// @notice Vault transfers tokens to strategy then calls this → supply to Aave
    function deployFunds(uint256 amount) external onlyVault {
        asset.approve(address(pool), amount);
        pool.supply(address(asset), amount, address(this), 0);
    }

    /// @notice Vault requests assets → withdraw from Aave back to vault
    function freeFunds(uint256 amount) external onlyVault {
        pool.withdraw(address(asset), amount, vault);
    }

    /// @notice Return total value managed by strategy
    function totalManagedAssets() external view returns (uint256) {
        uint256 aBal = aToken.balanceOf(address(this));   // aToken value
        uint256 idle = asset.balanceOf(address(this));    // unused idle funds
        return aBal + idle;
    }
}
