// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Allows users to 'vote' on rewards allocation based on the amount invested in selected LP pools
// The voting rights of users vs the rewadrsController/rewardsManager can be configured
// Weightings will be recalculated and pool reward allocations updated when:
    // a user or the RewardsManager updates thier votes 
    // a voting user deposits to or withdraws from a voting pool

// The gas costs will be optimized for a lower number of voting pools.
// Recommended number of pools between 1 and 3 (eg Protocol-Native, Native-USDC, Native - staked Native)
// Voting power will be more evenly allocated when the price of LP tokens in voting pools is similar

import './dependencies/SafeBEP20.sol';
import './dependencies/Ownable.sol';
import "./interfaces/IFarmMaster.sol";
import "./dependencies/SafeMath.sol";
import "./dependencies/CheckContract.sol";

contract FarmingRewardsAllocator  is Ownable, CheckContract {
    using SafeMath for uint256;

    uint80 public constant ONE_HUNDRED_PERCENT = 10000;
    uint80 public constant MIN_USER_WEIGHTING = 0;  // 10%
    uint80 public constant INITIAL_USER_WEIGHTING = 6000; // 60% ensures overall decentralized control
    uint80 public constant TOTAL_ALLOC_PTS = 10000;
    bool public isInitialized;
    uint80 public userVotesWeighting;

    IFarmMaster public farmingContract;
    address public farmingContractAddress;
    address public rewardManager;

    struct Vote {
        uint256 pid;
        uint256 allocation;
    }

    struct PoolData {
        uint256 pid;
        address lpAddress;
    }

    mapping(address => Vote[]) public userVotes;
    mapping(address => uint256) public userVotingLpBalance;
    mapping(address => uint256) public totalVotingLpBalanceLastUserUpdate; // Total Farmed amount of voting LP at last user update
    mapping(uint256 => uint256) public totalUserVotesByPID;
    mapping(uint256 => uint256) public rewardManagerVotesByPID;
    uint256 public totalAllUserVotes;
    
    // LP pools used to calc weight of User voting rights 
    mapping(uint256 => bool) public isVotingPool;
    PoolData[] public votingPools; 

    modifier onlyRewardManager() {
        require(msg.sender == rewardManager,"Not authorized");
        _;
    }
    modifier onlyFarmingContract() {
        require(msg.sender == farmingContractAddress,"Not authorized");
        _;
    }

    event RewardManagerChanged(address newRewardManager);
    event UserVoteWeightingChanged(uint80 userVotesWeighting);
    event PoolAddedForVoting(address lpAddress);

    // Configuration functions

    function initialize(address _farmingContractAddress, uint256 _initialVotingRightsPID, address _rewardManager) external onlyOwner {
        require(!isInitialized,"Contract already initialized");
        require(_rewardManager != address(0),"Invalid address");
        checkContract(_farmingContractAddress);
        farmingContractAddress = _farmingContractAddress;
        farmingContract =IFarmMaster(_farmingContractAddress);
        rewardManager = _rewardManager;
        userVotesWeighting = INITIAL_USER_WEIGHTING;
        _enablePoolForVoting(_initialVotingRightsPID);
        isInitialized = true;
        emit RewardManagerChanged(_rewardManager);
    }

    function changeRewardManager(address _rewardManager) external onlyRewardManager {
        require(_rewardManager != address(0),"Invalid address");
        rewardManager = _rewardManager;
        emit RewardManagerChanged(_rewardManager);
    }

    // Sets the weighting given to user votes vs those given to the RewardManager 10000 = 100%
    function setImportanceOfUserVotes(uint80 _userVotesWeighting) external onlyOwner {
        require(_userVotesWeighting >= MIN_USER_WEIGHTING && _userVotesWeighting <= ONE_HUNDRED_PERCENT,"Invalid Weighting");
        userVotesWeighting = _userVotesWeighting;
        emit UserVoteWeightingChanged(userVotesWeighting);
    }

    // Allows user LP holdings for the specified pool to contribute to a users voting power
    // Only takes effect next time the user votes or their position for this pool is updated
    function enablePoolForVoting(uint256 _pid) external onlyOwner {
        require(isInitialized,"Contract not initialized");
        _enablePoolForVoting(_pid);
    }
    function _enablePoolForVoting(uint256 _pid) internal {
        require(_pid < farmingContract.poolLength(),"Invalid Pool");
        require(!isVotingPool[_pid],"Already Enabled");
        (address lpAddress,,,) = farmingContract.poolInfo(_pid);
        votingPools.push(PoolData(_pid, lpAddress));
        isVotingPool[_pid] = true;
        emit PoolAddedForVoting(lpAddress);
    }
    // Stops the specified pool from contributibuting to user voting power
    // Only takes effect next time the user votes or their position for this pool is updated
    function disablePoolForVoting(uint256 _pid) external onlyOwner {
        require(isInitialized,"Contract not initialized");
        require(_pid < farmingContract.poolLength(), "Invalid Pool");
        require(isVotingPool[_pid],"Not a voting poold");  
        (address lpAddress,,,) = farmingContract.poolInfo(_pid);
        for (uint256 i = 0; i < votingPools.length; i++) {
            if (votingPools[i].lpAddress == lpAddress) {
                votingPools[i] = votingPools[votingPools.length - 1];
                votingPools.pop();
                isVotingPool[_pid] = false;
                break;
            }
        }
    }

    // Core functions

    function castRewardManagerVotes(Vote[] memory _voteAllocation) external onlyRewardManager {
        require(isInitialized,"Contract not initialized");
        _checkVotesValid(_voteAllocation);
        // Remove existing rewardManager votes
        uint256 numberOfPools = farmingContract.poolLength();
        for (uint256 i = 0; i < numberOfPools; i++) {
            rewardManagerVotesByPID[i] = 0;
        }
        // Set new votes        
        for (uint256 i = 0; i < _voteAllocation.length; i++) {
            rewardManagerVotesByPID[_voteAllocation[i].pid] = _voteAllocation[i].allocation;
        }
        _updatePoolAllocations();
    }

    // called by the farming contract whenever a user updates LP balance
    function updateVoting(address _user, uint256 _pid) external onlyFarmingContract {
        // only need to update if the pool is a voting pool and the user has voted
        if(isInitialized && isVotingPool[_pid] && userVotes[_user].length > 0){
            _castVote(_user, userVotes[_user]);
        }
    }

    // called by user when they want to update their vote weightings
    function castUserVote(Vote[] memory _voteAllocation) external {
        require(isInitialized,"Contract not initialized");
        _checkVotesValid(_voteAllocation);
        require(_getUserVotingLPBalance(msg.sender) > 0,"No voting rights");
        _castVote(msg.sender, _voteAllocation);
    }

    function removeUserVotes(bool _removeVoting) external {
        require(_removeVoting,"Must confirm removal");
        Vote[] memory emptyVotes = new Vote[](0);
        _castVote(msg.sender, emptyVotes);
    }

    // Cast votes to allocate user votes weightings for different pools
    function _castVote(address _user, Vote[] memory voteAllocation) private {
        // First, remove the user's old votes from the totalVotes
        for (uint256 i = 0; i < userVotes[_user].length; i++) {
            Vote memory oldVote = userVotes[_user][i];
            uint256 scaledOldVote = oldVote.allocation.mul(userVotingLpBalance[_user]).div(totalVotingLpBalanceLastUserUpdate[_user]);
            totalUserVotesByPID[oldVote.pid] = totalUserVotesByPID[oldVote.pid].sub(scaledOldVote);
            totalAllUserVotes = totalAllUserVotes.sub(scaledOldVote);
        }
        // Clear existing votes mapping for user
        delete userVotes[_user]; 
        if(voteAllocation.length >0){
            // update balances for new vote weightings
            userVotingLpBalance[_user] = _getUserVotingLPBalance(_user);
            totalVotingLpBalanceLastUserUpdate[_user] = _getTotalFarmedAllVotingPools();

            // Add the user's new votes to the totalVotes, scaled by their balance
            for (uint256 j = 0; j < voteAllocation.length; j++) {
                Vote memory newVote = voteAllocation[j];
                uint256 scaledNewVote = newVote.allocation.mul(userVotingLpBalance[_user]).div(totalVotingLpBalanceLastUserUpdate[_user]);
                totalUserVotesByPID[newVote.pid] = totalUserVotesByPID[newVote.pid].add(scaledNewVote);
                totalAllUserVotes = totalAllUserVotes.add(scaledNewVote);
                userVotes[_user].push(newVote); // Set new votes for this user
            }        
        }
        _updatePoolAllocations();
    }

    function _updatePoolAllocations() internal {
        uint256 numberOfPools = farmingContract.poolLength();
        uint256 rewardManagerWeighting = ONE_HUNDRED_PERCENT;
        rewardManagerWeighting = rewardManagerWeighting.sub(userVotesWeighting);
        // update existing reward distributions before changing allocations
        farmingContract.massUpdatePools();

        for (uint256 i = 0; i < numberOfPools; i++) {
            uint256 rewardAllocation = 0;
            if (totalUserVotesByPID[i] > 0 && totalAllUserVotes > 0) {
                rewardAllocation = TOTAL_ALLOC_PTS;
                rewardAllocation = rewardAllocation.mul(userVotesWeighting).mul(totalUserVotesByPID[i]).div(totalAllUserVotes).div(ONE_HUNDRED_PERCENT);
            }
            if (rewardManagerVotesByPID[i] > 0) {
                uint256 rewarManagerAllocation = TOTAL_ALLOC_PTS;
                rewarManagerAllocation = rewarManagerAllocation.mul(rewardManagerWeighting).mul(rewardManagerVotesByPID[i]).div(ONE_HUNDRED_PERCENT);
                rewardAllocation = rewardAllocation.add(rewarManagerAllocation.div(ONE_HUNDRED_PERCENT));
            }
            farmingContract.set(i, rewardAllocation, false);
        }
    }

    // Helper functions

    // Checks for valid PID, PIDs not repeated and vote allocation = 100%
    function _checkVotesValid(Vote[] memory _voteAllocation) internal view {
        require(_voteAllocation.length > 0, "Vote allocation cannot be empty");
        uint256 numberOfPools = farmingContract.poolLength();
        uint256 sumOfAllocations = 0;
        uint256[] memory seenPIDs = new uint256[](_voteAllocation.length);
        uint256 seenCount = 0;
        for (uint256 i = 0; i < _voteAllocation.length; i++) {
            require(_voteAllocation[i].pid < numberOfPools, "Not a valid pool");

            // Check for duplicate PIDs
            for (uint256 j = 0; j < seenCount; j++) {
                require(seenPIDs[j] != _voteAllocation[i].pid, "Cannot vote for the same pool twice");
            }
            seenPIDs[seenCount] = _voteAllocation[i].pid;
            seenCount++;
            sumOfAllocations = sumOfAllocations.add(_voteAllocation[i].allocation);
        }
        require(sumOfAllocations == ONE_HUNDRED_PERCENT, "Voting allocations must equal 100%");
    }

    function _getTotalSupplyAllVotingPools() internal view returns(uint256){
        uint256 totalSupplyAllVotingPools = 0;
        for (uint256 i = 0; i < votingPools.length; i++) {
            totalSupplyAllVotingPools =  totalSupplyAllVotingPools.add(IBEP20(votingPools[i].lpAddress).totalSupply());
        }
        return totalSupplyAllVotingPools;
    }

    function getTotalFarmedAllVotingPools() external view returns(uint256){
        return _getTotalFarmedAllVotingPools();
    }

    function _getTotalFarmedAllVotingPools() internal view returns(uint256){
        uint256 totalFarmedAllVotingPools = 0;
        for (uint256 i = 0; i < votingPools.length; i++) {
            totalFarmedAllVotingPools =  totalFarmedAllVotingPools.add(IBEP20(votingPools[i].lpAddress).balanceOf(farmingContractAddress));
        }
        return totalFarmedAllVotingPools;
    }

    // Returns the users farmed token balance for all LPs that give voting rights
    function _getUserVotingLPBalance(address _user) internal view returns(uint256){
        uint256 userBalanceAllVotingPools = 0;
        for (uint256 i = 0; i < votingPools.length; i++) {
            (uint256 farmedAmount, ) = farmingContract.userInfo(votingPools[i].pid, _user);
            userBalanceAllVotingPools =  userBalanceAllVotingPools.add(farmedAmount);
        }
        return userBalanceAllVotingPools;
    }

    // external getter functions

    function getUserVotes(address _user) external view returns (Vote[] memory){
        return userVotes[_user];
    }

    function getRewardManagerVotes() external view returns (Vote[] memory) {
        uint256 numberOfPools = farmingContract.poolLength();
        uint256 count = 0;
        for (uint256 i = 0; i < numberOfPools; i++) {
            if (rewardManagerVotesByPID[i] > 0) {
                count++;
            }
        }
        Vote[] memory results = new Vote[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < numberOfPools; i++) {
            if (rewardManagerVotesByPID[i] > 0) {
                results[index] = Vote({ pid: i, allocation: rewardManagerVotesByPID[i] });
                index++;
            }
        }
        return results;
    }

    function getUserVotingLpBalance(address _user) external view returns (uint256){
        return _getUserVotingLPBalance(_user);
    }

    // Total Supply of voting LP pools at last user update
    function getTotalVotingLpBalanceLastUserUpdate(address _user) external view returns (uint256){
        return totalVotingLpBalanceLastUserUpdate[_user];
    }

    function getTotalUserVotesByPID(uint256 _pid) external view returns (uint256){
        return totalUserVotesByPID[_pid];
    }

    function getIsVotingPool(uint256 _pid) external view returns (bool){
        return isVotingPool[_pid];
    }

    function getVotingPools() public view returns (PoolData[] memory) {
        return votingPools;
    }
}