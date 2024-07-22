// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IFarmingRewardsAllocator {
    struct Vote {
        uint256 pid;
        uint256 allocation;
    }

    // Events
    event RewardManagerChanged(address newRewardManager);
    event UserVoteWeightingChanged(uint80 userVotesWeighting);
    event PoolAddedForVoting(address lpAddress);

    // Core functions
    function castRewardManagerVotes(Vote[] memory _voteAllocation) external;

    function castUserVote(Vote[] memory _voteAllocation) external;

    function removeUserVotes(bool _removeVoting) external;

     // Function to be called by the farming contract
    function updateVoting(address _user, uint256 _pid) external;

    // External getter functions
    function getUserVotes(address _user) external view returns (Vote[] memory);

    function getRewardManagerVotes(address _user) external view returns (Vote[] memory);
}
