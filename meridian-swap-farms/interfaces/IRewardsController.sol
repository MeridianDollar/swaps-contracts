// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IRewardsController {
    // Getter functions
    function rewardToken() external view returns (address);
    function rewardsPerBlock() external view returns (uint256);
    function averageBlockTime() external view returns (uint256);
    function getRewardsStartBlock() external view returns (uint256);
    function isInitialized() external view returns (bool);

    // Configuration functions
    function initialize(address _farmingContractAddress, address _rewardManager, address _rewardToken) external;
    function changeRewardManager(address _newRewardManager) external;

    // Core contract functions
    function setRewardsCycle(uint256 _startTime, uint256 _amount, uint256 _rewardsPerBlock) external;
    function getRewardsEndTime() external view returns (uint256);
}
