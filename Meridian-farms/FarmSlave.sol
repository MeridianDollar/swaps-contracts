// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// FarmMaster contract opens and manages farming positions on FarmSlave on behalf of users
// FarmSlave positions mirror user positions on FarmMaster to accrue rewards in secondary reward token
// ERC20 rewards are set and managed by a RewardsController contract from which parameters are read by this contract
// The rewards controller will be different to the FarmMaster rewards controller as it will control a different reward token
// Farming rewards allocation is derived from the FarmingRewardsAllocator via the FarmMaster contract

import "./dependencies/SafeMath.sol";
import './dependencies/SafeBEP20.sol';
import './dependencies/Ownable.sol';
import "./dependencies/SafeERC20.sol";
import "./dependencies/CheckContract.sol";
import './interfaces/IBEP20.sol';
import "./interfaces/IRewardsController.sol";
import "./interfaces/IFarmMaster.sol";

contract FarmSlave is Ownable, CheckContract {
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
    // If set then rewards from this contract will be set by community voting
    bool public isCommunityControl;

    // Info of each pool.
    struct PoolInfo {
        address lpAddress;           // Address of LP token contract.
        uint256 balanceOfThis;     // Proxy to record the notional amount of LP managed by this contract
        uint256 allocPoint;       // How many allocation points assigned to this pool. Rewards to distribute per block.
        uint256 lastRewardBlock;  // Last block number that rewards distribution occurs.
        uint256 accRewardsPerShare; // Accumulated rewards per share, times 1e12. See below.
        uint256 lastUpdateTime;     // Used to ensure pools are regularly updated
    }

    // The Reward token set by the RewardsController.sol
    IERC20 public rewardToken;
    // The farming rewards controller contract
    IRewardsController public rewardsController;
    // Master farming contract contols all slave contracts
    address public farmMaster;
    // Community rewards address.
    address public communityRewardsContract;
    // Can set rewards allocations if rewards not controlled by community (isCommunityControl = false)
    address public authSetter;
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

    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when the rewards cycle starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 pid, uint256 amount);
    event RewardsControllerChanged(address _newRewardsController);
    event RemoveAccidentalDeposits(address _token, uint256 amount);

    modifier onlyRewardsController() {
        require(msg.sender == address(rewardsController),"Not authorized");
        _;
    }

    modifier onlyFarmMaster() {
        require(msg.sender == farmMaster,"Not authorized");
        _;
    }

    // When contract is in community control rewards allocation is set by the FarmMaster contract
    // otherwise rewards can be controlled by an authorized address
    modifier onlyAuthSetter() {
        require(msg.sender == farmMaster || 
        (msg.sender == authSetter && !isCommunityControl),
        "Not authorized");
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
        isCommunityControl = true;
        authSetter = msg.sender;
    }

    function initialize(address _rewardsController, address _farmMaster) external onlyOwner {
        require(!isInitialized,"Contract already initialized");
        require(_rewardsController != address(0), "Invalid address");
        checkContract(_farmMaster);
        rewardsController = IRewardsController(_rewardsController);
        farmMaster = _farmMaster;
        require(rewardsController.isInitialized(),"Rewards controller must be inizialized");
        rewardToken = IERC20(rewardsController.rewardToken());
        rewardsPerBlock = rewardsController.rewardsPerBlock();
        startBlock = rewardsController.getRewardsStartBlock();
        isInitialized = true;
    }

    function changeAuthSetter (address _authSetter) external {
        require(msg.sender == authSetter,"Not authorized");
        authSetter =_authSetter;
    }

    // controls if the rewards allocation is set locally or by the FarmMaster contract (community voting)
    function changeIsCommunityControl() external {
        require(msg.sender == authSetter,"Not authorized");
        isCommunityControl = !isCommunityControl;
        // if switching to community control pull the allocPoint settings from FarmMaster
        if(isCommunityControl){
            IFarmMaster farmMasterContract = IFarmMaster(farmMaster);
            for (uint256 i = 0; i < poolInfo.length; ++i) {
                (, uint256 allocPoint,,) = farmMasterContract.poolInfo(i);
                uint256 prevAllocPoint = poolInfo[i].allocPoint;
                poolInfo[i].allocPoint = allocPoint;
                if (prevAllocPoint != allocPoint) {
                    totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(allocPoint);
                }
            }
        }
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

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the Farm Master contract.
    function add(IBEP20 _lpToken, uint256 allocPoint, bool _withUpdate) external onlyFarmMaster {
        checkContract(address(_lpToken));
        require(!lpPools[address(_lpToken)],"LP Pool already exists");
        lpPools[address(_lpToken)] = true;
        
        if (_withUpdate) {
            _massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);

        poolInfo.push(PoolInfo({
            lpAddress: address(_lpToken),
            balanceOfThis: 0,
            allocPoint: allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardsPerShare: 0,
            lastUpdateTime: block.timestamp
        }));
    }

    // Update the given pool's reward allocation points. 
    // If contract isCommunityControl then can only be called by the FarmMaster contract otherwise are set by an authorised address
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyAuthSetter {
        require(_pid < poolInfo.length, "Invalid pool ID");
        if (_withUpdate) {
            _massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
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
        uint256 lpSupply = pool.balanceOfThis;
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

    // Called by FarmingMaster to update existing pool rewards before the reward allocations change
    function massUpdatePools() external {
        _massUpdatePools();
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
        uint256 lpSupply = pool.balanceOfThis;
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

    // Action and record the deposit of LP tokens to FarmMaster contract and earn rewards allocation from this slave.
    // Pay any already existing rewards earned for this pid from this slave
    function deposit(uint256 _pid, uint256 _amount, address _user) external onlyFarmMaster {
        require(_pid < poolInfo.length, "Invalid pool ID");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid, false);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardsPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeRewardsTransfer(_user, pending);
            }
        }
        if (_amount > 0) {
            pool.balanceOfThis = pool.balanceOfThis.add(_amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }

    // Action and record withdrawal LP tokens from FarmMaster.  
    // Pay any rewards earned for this pid from this slave
    function withdraw(uint256 _pid, uint256 _amount, address _user) external onlyFarmMaster {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 withdrawableAmount = _amount > user.amount ? user.amount : _amount;
        withdrawableAmount = withdrawableAmount > pool.balanceOfThis ? pool.balanceOfThis : withdrawableAmount;

        updatePool(_pid, false);
        uint256 pending = user.amount.mul(pool.accRewardsPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeRewardsTransfer(_user, pending);
        }

        if(withdrawableAmount > 0) {
            user.amount = user.amount.sub(withdrawableAmount);
            pool.balanceOfThis = pool.balanceOfThis.sub(withdrawableAmount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e12);
        emit Withdraw(_user, _pid, withdrawableAmount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid, address _user) external onlyFarmMaster {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        pool.balanceOfThis = pool.balanceOfThis.sub(user.amount);

        emit EmergencyWithdraw(_user, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Function to help users who accidentally deposit tokens to this contract
    // This contract should only hold reward tokens so any other token can be removed by owner
    function removeAccidentalDeposits(IERC20 _token) public onlyOwner {
        require(_token != rewardToken,"Forbidden: Cannot withdraw reward token");
        uint256 amount = _token.balanceOf(address(this));
        _token.safeTransfer(msg.sender, amount);
        
        emit RemoveAccidentalDeposits(address(_token), amount);
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


    // Update Community Rewards address .
    function communityRewardsAddress(address _communityRewardsContract) public onlyOwner {
        communityRewardsContract = _communityRewardsContract;
    }

    // getter functions for frontend

    function getRewardsPerSecond() public view returns(uint256) {
        uint256 averageBlockTime = rewardsController.averageBlockTime();
        uint256 rewardsPerSecond = 0;
        if(averageBlockTime > 0){
            rewardsPerSecond = rewardsPerBlock.mul(10000).div(averageBlockTime);  // 10,000 = 1 per block
        }
        return rewardsPerSecond;
    }

     function getRewardTokenAddress() public view returns(address) {
        return address(rewardToken);        
    }

     function getRewardTokenSymbol() public view returns(string memory) {
        return rewardToken.symbol();        
    }

}
