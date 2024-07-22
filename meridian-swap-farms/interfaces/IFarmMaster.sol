// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

   interface IFarmMaster {

    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
    }

    struct PoolInfo {
        address lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool.
        uint256 lastRewardBlock;  // Last block number that rewards distribution occurs.
        uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12.
        uint256 lastUpdateTime;     // Used to ensure pools are regularly updated
    }
    function userInfo(uint256 pool, address user) external view returns (uint256 amount, uint256 rewardDebt);
    function poolInfo(uint256 index) external view returns (address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accRewardPerShare);
    function poolLength() external view returns (uint256);
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external;
    function updateRewardsParameters(uint256 _rewardsStartBlock, uint256 _rewardsPerBlock)external;
    function massUpdatePools() external;

   }
