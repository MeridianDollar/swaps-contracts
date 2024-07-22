// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import './IBEP20.sol';

interface IFarmSlave {

struct UserInfo {
    uint256 amount;     // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt.
}

    struct PoolInfo {
        address lpAddress;           // Address of LP token contract.
        uint256 balanceOfThis;     // Proxy to record the notional amount of LP managed by this contract
        uint256 allocPoint;       // How many allocation points assigned to this pool. Rewards to distribute per block.
        uint256 lastRewardBlock;  // Last block number that rewards distribution occurs.
        uint256 accRewardsPerShare; // Accumulated rewards per share, times 1e12. See below.
        uint256 lastUpdateTime;     // Used to ensure pools are regularly updated
    }

function isInitialized() external view returns (bool);
function isCommunityControl() external view returns (bool);
function userInfo(uint256 pool, address user) external view returns (uint256 amount, uint256 rewardDebt);
function poolInfo(uint256 index) external view returns (address lpToken, uint256 balanceOfThis, uint256 allocPoint, uint256 lastRewardBlock, uint256 accRewardPerShare, uint256 lastUpdateTime);
function poolLength() external view returns (uint256);
function add(IBEP20 _lpToken, uint256 allocPoint, bool _withUpdate) external;
function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external;
function updateRewardsParameters(uint256 _rewardsStartBlock, uint256 _rewardsPerBlock)external;
function massUpdatePools() external;
function deposit(uint256 _pid, uint256 _amount, address _user) external;
function withdraw(uint256 _pid, uint256 _amount, address _user) external;
function emergencyWithdraw(uint256 _pid, address _user) external;

}
