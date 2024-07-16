// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './dependencies/SafeMath.sol';
import './interfaces/IBEP20.sol';
import './dependencies/SafeBEP20.sol';
import './dependencies/Ownable.sol';
import "./dependencies/CheckContract.sol";
import "./dependencies/SafeERC20.sol";
import "./interfaces/IFarmMaster.sol";

// Rewards controller sets and manages parameters associated with farming rewards
// 1) Configures each reward cycle
// 2) Holds tokens that will be used for rewards up to the point when they have been earned
// 3) Controls the rate at which tokens will be distrubuted 

// There can only be one rewards cycle active at any time
// Once set the reward token is fixed as the farming contract can only handle a single token
// Other rewards parameters can be updated for each cycle
// Each reward cycle configuration has:
//  - a start time
//  - an amount of tokens that will be used for rewards
//  - A rate at which tokens will be distributed ie the tokens per block allocation 
//  - From this a duration or end time for the rewards cycle can be calculated
//  - Rewards can be added or removed by the rewards manager at any time to extend or shorten the rewards cycle  
//  - If a new rewards cycle is set up then the current rewards cycle will immediately end and the new cycle will start at the designated start time
//  - Any unused rewards tokens can be retrieved by the rewards owner
  
contract RewardsController is Ownable, CheckContract {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    uint public averageBlockTime;  // Block time in seconds expressed in ether 1E18 = 1 sec

    IERC20 public rewardToken;
    address public farmingContractAddress;
    address public rewardManager;
    bool public isInitialized;

    uint256 public rewardsStartTime;
    uint256 public rewardsPerBlock;

    event RewardManagerChanged(address _newRewardManager);
    event RewardsCycleSet(uint256 _startTime, uint256 _amount, uint256 _rewardsPerBlock);

    modifier onlyRewardManager() {
        require(msg.sender == rewardManager,"Not authorized");
        _;
    }

    // Configuration functions

    // @param _averageBlockTime  - frequency that new blocks are created on given chain 1 second = 10
    function initialize(address _farmingContractAddress, address _rewardManager, address _rewardToken, uint256 _averageBlockTime) external onlyOwner {
        require(!isInitialized,"Contract already initialized");
        require(_rewardManager != address(0),"Invalid address");
        require(_averageBlockTime >= 1 && _averageBlockTime <= 18000,"Block frequency must be between 1 (0.1 Sec) and 18000");
        checkContract(_farmingContractAddress);
        checkContract(_rewardToken);
        farmingContractAddress = _farmingContractAddress;
        rewardManager = _rewardManager;
        rewardToken = IERC20(_rewardToken);
        averageBlockTime = _averageBlockTime.mul(1e18).div(10);
        isInitialized = true;
        renounceOwnership();
        emit RewardManagerChanged(_rewardManager);
    }

    function changeRewardManager(address _newRewardManager) external onlyRewardManager {
        require(_newRewardManager != address(0),"Invalid address");
        rewardManager = _newRewardManager;
        emit RewardManagerChanged(_newRewardManager);
    }

    // Core contract functions

    // _startTime - unix timestamp
    // _amount - total available rewards in this cycle x 1E18
    // _rewardsPerBlock - reward allocation per block x 1E18
    function setRewardsCycle( uint256 _startTime, uint256 _amount, uint256 _rewardsPerBlock) public onlyRewardManager {
        require(isInitialized,"Contract not initialized");
        require(_startTime >= block.timestamp,"Start time cannot be in the past");
        require(_amount > 0 || rewardToken.balanceOf(address(this)) > 0,"Available tokens must be more than zero");
        require(_rewardsPerBlock > 0,"Rewards rate must be more than zero");
        // receive tokens from rewardsManager
        if(_amount > 0) {
            rewardToken.safeTransferFrom(rewardManager, address(this), _amount);
        }
        rewardsStartTime = _startTime;
        rewardsPerBlock = _rewardsPerBlock;
        // we need to update the farm pools in case the reward parameters have changed
        IFarmMaster farmingContract = IFarmMaster(farmingContractAddress);
        farmingContract.updateRewardsParameters(getRewardsStartBlock(), rewardsPerBlock);

        // Allow the farming contract to spend the rewards. - Unlimited  
        // The reward manager can simply transfer future tokens to this contract to continue the current rewards cycle 
        // Allowance can be reduced by calling reduceAllowance
        rewardToken.approve(farmingContractAddress, uint256(-1));
      
        emit RewardsCycleSet(_startTime, _amount, _rewardsPerBlock);
    }

    // Allows the Rewards Manager to withdraw excess rewards or any tokens that were not intended to be sent to the contract
    function withdrawToken(address _token, uint256 _amount) public onlyRewardManager {
        IERC20 token = IERC20(_token);
        require(_amount > 0 && _amount <= token.balanceOf(address(this)), "Incorrect withdrawal amount");
        token.safeTransfer(rewardManager, _amount);
    }


    // Getter functions

    function getRewardsEndTime() external view returns(uint){
        if(rewardsPerBlock <= 0 ) {
            return 0;
        }
        if( block.timestamp >= rewardsStartTime) {
            return block.timestamp.add(rewardToken.balanceOf(address(this)).div(rewardsPerBlock));
        }
        return rewardsStartTime.add(rewardToken.balanceOf(address(this)).div(rewardsPerBlock));
    }

    function getRewardsStartBlock() public view returns (uint256) {
        uint256 currentBlockNumber = block.number;
        uint256 currentTimestamp = block.timestamp;
        if(rewardsStartTime <= currentTimestamp){
            uint256 timeDifference = currentTimestamp - rewardsStartTime;
            uint256 estimatedBlocks = timeDifference * (1 ether / averageBlockTime);
            return currentBlockNumber - estimatedBlocks;
        }
        uint256 timeDifference = rewardsStartTime - currentTimestamp;
        uint256 estimatedBlocks = timeDifference * (1 ether / averageBlockTime);
        return currentBlockNumber + estimatedBlocks;
    }
}