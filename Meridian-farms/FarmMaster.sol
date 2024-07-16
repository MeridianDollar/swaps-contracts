// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./dependencies/SafeMath.sol";
import './interfaces/IBEP20.sol';
import './dependencies/SafeBEP20.sol';
import './dependencies/Ownable.sol';

import "./dependencies/SafeERC20.sol";
import "./interfaces/IRewardsController.sol";
import "./dependencies/CheckContract.sol";
import "./interfaces/IFarmingRewardsAllocator.sol";
import "./interfaces/IFarmSlave.sol";

// import "@nomiclabs/buidler/console.sol";

// FarmMaster manages the protocol liquidity farms.
// ERC20 rewards are set and managed by the RewardsController contract from which parameters are read by this contract
// Farming rewards allocation is derived from the FarmingRewardsAllocator 
// which uses community voting to establish the reward allocations to each farm
// Governance is devolved to the community and the rewardsController and the contract owner can only add new farms
// this power will also be transferred to a governance smart contract in time
//

contract FarmMaster is Ownable, CheckContract {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    
        //   pending reward = (user.amount * pool.accRewardsPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accRewardsPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    uint256 public constant ONE_DAY = 24 * 60 * 60;
    bool public isInitialized;

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Rewards to distribute per block.
        uint256 lastRewardBlock;  // Last block number that rewards distribution occurs.
        uint256 accRewardsPerShare; // Accumulated rewards per share, times 1e12. See below.
        uint256 lastUpdateTime;     // Used to ensure pools are regularly updated
    }

    // The Reward token set by the RewardsController.sol
    IERC20 public rewardToken;
    // The farming rewards controller contract
    IRewardsController public rewardsController;
    // Voting contract that awards allocation points to farms
    address public rewardsAllocator;
    // Community rewards address.
    address public communityRewardsContract;
    // Reward tokens issued per block.
    uint256 public rewardsPerBlock;
    // Community reward allocation
    uint256 public communityIssuanceRate;
    // Bonus muliplier for early adopters.
    uint256 public BONUS_MULTIPLIER = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Log of LP addresses already included in farms to prevent adding same LP twice
    mapping(address => bool) public lpPools;
    // Circular tracker to hold reference to last updated pool
    uint256 public poolUpdateTracker;

    // Record of slave farming contracts that issue rewards in different tokens
    address[] public slaveFarms;
    mapping (address => bool) isSlave;

    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when the rewards cycle starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardsAllocatorChanged(address _newRewardsAllocator);
    event RewardsControllerChanged(address _newRewardsController);

    modifier onlyRewardsAllocator() {
        require(msg.sender == rewardsAllocator,"Not authorized");
        _;
    }

    modifier onlyRewardsController() {
        require(msg.sender == address(rewardsController),"Not authorized");
        _;
    }

    constructor(
        address _communityRewardsContract,
        uint256 _communityIssuanceRate  
    ) public {
        require(_communityIssuanceRate >= 0 && _communityIssuanceRate <= 33, "Max Community Issuance 33%");
        communityRewardsContract = _communityRewardsContract;
        communityIssuanceRate = _communityIssuanceRate;
        poolUpdateTracker = 0;
    }

    function initialize(address _rewardsController, address _rewardsAllocator) external onlyOwner {
        require(!isInitialized,"Contract already initialized");
        require(_rewardsController != address(0), "Invalid address");
        require(_rewardsAllocator != address(0), "Invalid address");
        rewardsController = IRewardsController(_rewardsController);
        rewardsAllocator = _rewardsAllocator;
        require(rewardsController.isInitialized(),"Rewards controller must be inizialized");
        rewardToken = IERC20(rewardsController.rewardToken());
        rewardsPerBlock = rewardsController.rewardsPerBlock();
        startBlock = rewardsController.getRewardsStartBlock();
        isInitialized = true;
    }

    function changeRewardsAllocator(address _newRewardsAllocator) external onlyOwner {
        require(_newRewardsAllocator != address(0),"Invalid address");
        rewardsAllocator = _newRewardsAllocator;
        emit RewardsAllocatorChanged(rewardsAllocator);
    }

    function changeRewardsController(address _newRewardsController) external onlyOwner {
        require(_newRewardsController != address(0),"Invalid address");
        // Ensure earned rewards are correct before controller is upgraded
        _massUpdatePools();
        rewardsController = IRewardsController(_newRewardsController);
        require(rewardsController.isInitialized(),"Rewards controller must be inizialized");
        require(IERC20(rewardsController.rewardToken()) == rewardToken," Must keep the same reward token");
        rewardsPerBlock = rewardsController.rewardsPerBlock();
        startBlock = rewardsController.getRewardsStartBlock();
        emit RewardsControllerChanged(address(rewardsController));
    }

    // Update Community Rewards address .
    function communityRewardsAddress(address _communityRewardsContract) public onlyOwner {
        communityRewardsContract = _communityRewardsContract;
    }

    // Update Community Issuace rate .
    function changeCommunityIssuanceRate(uint256 _communityIssuanceRate) public onlyOwner {
        require(_communityIssuanceRate >= 0 && _communityIssuanceRate <= 33, "Max Community Issuance 33%");
        communityIssuanceRate = _communityIssuanceRate;
    }

    // Adds a new slave rewards contract.  
    // New slaves must be initialized but the PoolInfo array must be empty
    function addSlaveFarm(address _newSlave) external onlyOwner {
        require(isInitialized,"Contract not initialized");
        checkContract(_newSlave);
        IFarmSlave newSlaveContract = IFarmSlave(_newSlave);
        require(newSlaveContract.isInitialized(),"Slave not initialized");
        require(newSlaveContract.poolLength() <= 0 ,"Pools must be empty");
        // add the slave to the slave records
        slaveFarms.push(_newSlave);
        isSlave[_newSlave] = true;
        // Now push any existing pools to the new slave
        for (uint256 i = 0; i < poolInfo.length; ++i) {
            newSlaveContract.add(poolInfo[i].lpToken, poolInfo[i].allocPoint ,false);
        }
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(IBEP20 _lpToken, bool _withUpdate) public onlyOwner {
        checkContract(address(_lpToken));
        require(!lpPools[address(_lpToken)],"LP Pool already exists");
        lpPools[address(_lpToken)] = true;
        // By default no rewards are initially allocated to pools.  They need to be set by rewardsAllocator
        uint256 allocPoint = 0;
        
        if (_withUpdate) {
            _massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardsPerShare: 0,
            lastUpdateTime: block.timestamp
        }));

        // If there are other reward token contracts then we need to add this pool to those contracts
        for (uint256 i = 0; i < slaveFarms.length; i++) {
            IFarmSlave slaveContract = IFarmSlave(slaveFarms[i]);
            slaveContract.add(_lpToken, allocPoint, _withUpdate);
        }
    }

    // Update the given pool's reward allocation points. Can only be called by the Farming Rewards Allocator contract.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyRewardsAllocator {
        require(_pid < poolInfo.length, "Invalid pool ID");
        if (_withUpdate) {
            _massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }

        // If there are other reward token contracts controlled by the rewardsAllocator then we need to set those contracts
        for (uint256 i = 0; i < slaveFarms.length; i++) {
            IFarmSlave slaveContract = IFarmSlave(slaveFarms[i]);
            if(slaveContract.isCommunityControl()){
                slaveContract.set(_pid, _allocPoint, _withUpdate);
            }
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending rewards on frontend.
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardsPerShare = pool.accRewardsPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 poolRewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            // As rewards may may not be continuous check that sufficient rewards are available 
            if(rewardToken.balanceOf(address(rewardsController)) >= poolRewards) {
                uint256 communityIssuance = poolRewards.mul(communityIssuanceRate).div(100);
                poolRewards = poolRewards.sub(communityIssuance);
                accRewardsPerShare = accRewardsPerShare.add(poolRewards.mul(1e12).div(lpSupply));
            }
        }
        return user.amount.mul(accRewardsPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Called by RewardsController when a new rewards cycle is set up
    function updateRewardsParameters(uint256 _rewardsStartBlock, uint256 _rewardsPerBlock) external onlyRewardsController {
        startBlock = _rewardsStartBlock;
        _massUpdatePools();
        // Ensure that the rewards per block is updated to latest value immediately after all pools have been updated
        rewardsPerBlock = _rewardsPerBlock;
    }

    // Called by FarmingRewardsAllocator to update existing pool rewards before the reward allocations change
    function massUpdatePools() external {
        _massUpdatePools();

        // If there are other reward token contracts then we need to update those contracts
        for (uint256 i = 0; i < slaveFarms.length; i++) {
            IFarmSlave slaveContract = IFarmSlave(slaveFarms[i]);
            slaveContract.massUpdatePools();
        }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function _massUpdatePools() internal {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }
    }

    function updatePool(uint256 _pid, bool _isMassUpdate) public {
        _updatePool(_pid);
        // A circular buffer is used to ensure that all pools are updated regularly but only required if this is not a massupdate 
        if(!_isMassUpdate) {
            uint256 nextPid = (poolUpdateTracker + 1) % poolInfo.length;
            // if the next pool in the buffer has not been updated recently then update that one as well
            if (block.timestamp - poolInfo[nextPid].lastUpdateTime > ONE_DAY) {
                _updatePool(nextPid);
            }
            poolUpdateTracker = nextPid;
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function _updatePool(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if(block.number <= startBlock){
            pool.lastRewardBlock = startBlock;
            return;
        }
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 totalPoolAllocation = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        // As rewards may may not be continuous check that sufficient rewards are available before the distribution is set up
        if(rewardToken.balanceOf(address(rewardsController)) < totalPoolAllocation) {
            totalPoolAllocation = rewardToken.balanceOf(address(rewardsController));
        }
        if(totalPoolAllocation > 0) {
            uint256 communityIssuance = totalPoolAllocation.mul(communityIssuanceRate).div(100);
            uint256 poolRewards = totalPoolAllocation.sub(communityIssuance);

            rewardToken.safeTransferFrom(address(rewardsController), communityRewardsContract, communityIssuance);
            rewardToken.safeTransferFrom(address(rewardsController), address(this), poolRewards);
            pool.accRewardsPerShare = pool.accRewardsPerShare.add(poolRewards.mul(1e12).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
        pool.lastUpdateTime = block.timestamp;
    }

    // Deposit LP tokens to this contract to earn rewards allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        require(_pid < poolInfo.length, "Invalid pool ID");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid, false);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardsPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeRewardsTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e12);
        // If this Pool contributes to voting power and the user has voted then we need to update the reward allocations
        IFarmingRewardsAllocator(rewardsAllocator).updateVoting(msg.sender, _pid);

        // If there are other reward token contracts then we need to update the deposits for those contracts
        for (uint256 i = 0; i < slaveFarms.length; i++) {
            IFarmSlave slaveContract = IFarmSlave(slaveFarms[i]);
            slaveContract.deposit(_pid, _amount, msg.sender);
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from FarmMaster.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];

        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid, false);
        uint256 pending = user.amount.mul(pool.accRewardsPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeRewardsTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e12);
        // If this Pool contributes to voting power and the user has voted then we need to update the reward allocations
        IFarmingRewardsAllocator(rewardsAllocator).updateVoting(msg.sender, _pid);

        // If there are other reward token contracts then we need to update the positions for those contracts
        for (uint256 i = 0; i < slaveFarms.length; i++) {
            IFarmSlave slaveContract = IFarmSlave(slaveFarms[i]);
            slaveContract.withdraw(_pid, _amount, msg.sender);
        }

        emit Withdraw(msg.sender, _pid, _amount);
    }


    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // If there are other reward token contracts then we need to update the positions for those contracts
        for (uint256 i = 0; i < slaveFarms.length; i++) {
            IFarmSlave slaveContract = IFarmSlave(slaveFarms[i]);
            slaveContract.emergencyWithdraw(_pid, msg.sender);
        }

        pool.lpToken.safeTransfer(address(msg.sender), user.amount);

        // If this Pool contributes to voting power and the user has voted then we need to update the reward allocations
        IFarmingRewardsAllocator(rewardsAllocator).updateVoting(msg.sender, _pid);

        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe rewards transfer function, just in case if rounding error causes pool to not have enough rewards.
    function safeRewardsTransfer(address _to, uint256 _amount) internal {
        uint256 rewardsBal = rewardToken.balanceOf(address(this));
        if (_amount > rewardsBal) {
            rewardToken.transfer(_to, rewardsBal);
        } else {
            rewardToken.transfer(_to, _amount);
        }
    }

    function getSlaveFarms() external view returns(address[] memory){
        return slaveFarms;
    }
}
