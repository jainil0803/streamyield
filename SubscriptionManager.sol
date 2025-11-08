// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StreamYieldVault.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/math/Math.sol";

/// @title SubscriptionManager
/// @notice Pays subscriptions using ONLY the user's yield from the StreamYieldVault.
contract SubscriptionManager is Ownable {
    using Math for uint256;

    struct Subscription {
        address payee;       // who receives money (Netflix, Electricity company)
        uint256 amount;      // cost each period (e.g., 10 USDC)
        uint256 period;      // how often it's due (in seconds)
        uint8 priority;      // lower = higher priority
        uint256 nextDue;     // when the next payment is due
        bool active;         // if false → skipped
    }

    /// @notice The vault from which we pull yield.
    StreamYieldVault public immutable vault;

    /// @notice user → list of subscriptions
    mapping(address => Subscription[]) public subs;

    event SubAdded(address indexed user, uint256 indexed id, address payee, uint256 amount, uint256 period, uint8 priority);
    event SubUpdated(address indexed user, uint256 indexed id);
    event SubCancelled(address indexed user, uint256 indexed id);
    event SubPaid(address indexed user, uint256 indexed id, address payee, uint256 amount);

    constructor(StreamYieldVault _vault)
        Ownable(msg.sender)
    {
        vault = _vault;
    }

    /* -------------------------------------------------------------------------- */
    /*                          SUBSCRIPTION CREATION                             */
    /* -------------------------------------------------------------------------- */

    function addSubscription(
        address payee,
        uint256 amount,
        uint256 period,
        uint8 priority
    ) external returns (uint256 id) {
        require(payee != address(0), "invalid payee");
        require(amount > 0 && period > 0, "bad params");

        id = subs[msg.sender].length;

        subs[msg.sender].push(
            Subscription({
                payee: payee,
                amount: amount,
                period: period,
                priority: priority,
                nextDue: block.timestamp + period,
                active: true
            })
        );

        emit SubAdded(msg.sender, id, payee, amount, period, priority);
    }

    function updateSubscription(
        uint256 id,
        address payee,
        uint256 amount,
        uint256 period,
        uint8 priority,
        bool active
    ) external {
        Subscription storage s = subs[msg.sender][id];
        require(s.payee != address(0), "no subscription");

        s.payee = payee;
        s.amount = amount;
        s.period = period;
        s.priority = priority;
        s.active = active;

        emit SubUpdated(msg.sender, id);
    }

    function cancelSubscription(uint256 id) external {
        Subscription storage s = subs[msg.sender][id];
        require(s.payee != address(0), "no subscription");
        s.active = false;

        emit SubCancelled(msg.sender, id);
    }

    function getSubscriptions(address user) external view returns (Subscription[] memory) {
        return subs[user];
    }

    /* -------------------------------------------------------------------------- */
    /*                       PAYMENT PROCESSING (YIELD ONLY)                      */
    /* -------------------------------------------------------------------------- */

    /// @notice Process due subscriptions for a specific user.
    /// Pays highest-priority due subs first.
    function process(address user, uint256 maxCount) external {
        uint256 available = vault.availableYield(user);
        if (available == 0) return;

        for (uint256 i = 0; i < maxCount && available > 0; i++) {
            (bool found, uint256 idx) = _findHighestPriorityDue(user);
            if (!found) break;

            Subscription storage s = subs[user][idx];
            uint256 pay = s.amount.min(available);

            // PAY using yield-only
            vault.withdrawYieldFor(user, s.payee, pay);

            emit SubPaid(user, idx, s.payee, pay);

            // If fully paid → schedule next cycle
            if (pay == s.amount) {
                s.nextDue += s.period;
            } else {
                break; // Not enough yield to pay fully → stop
            }

            available = vault.availableYield(user);
        }
    }

    /// @notice Find the highest-priority subscription that is due.
    function _findHighestPriorityDue(address user) internal view returns (bool found, uint256 idx) {
        Subscription[] storage list = subs[user];
        uint8 best = type(uint8).max; // large number (worst priority)

        for (uint256 i = 0; i < list.length; i++) {
            Subscription storage s = list[i];
            if (!s.active) continue;
            if (block.timestamp < s.nextDue) continue;

            // Lower priority number = higher priority
            if (s.priority <= best) {
                best = s.priority;
                idx = i;
                found = true;
            }
        }
    }
}
