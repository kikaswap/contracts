// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../openzeppelin/contracts/access/Ownable.sol";
import "../openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKISS is IERC20 {
    function mint(address to, uint256 amount) external returns (bool);
    function getMaxSupply() external pure returns(uint256);
    function getMintInfo(address minter) external view returns (uint256 maxMint, uint256 nowMint);
}

contract KISSPools is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Mint(uint256 amount);
    event PoolAdded(POOL_TYPE poolType, address indexed stakedToken, uint256 allocPoint);
    event PoolSetted(address indexed stakedToken, uint256 allocPoint);
    event WithdrawReleased(address indexed user, uint256 indexed pid, uint256 amount);

    enum POOL_TYPE { Single, LP }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 harvestAmount;
        uint256 harvestTime;
        uint256 releasedAmount;
        uint256 releasedTime;
        uint256 leftAmount;
        uint256 tempReward;
    }

    struct PoolInfo {
        POOL_TYPE poolType;
        IERC20 stakedToken;           
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accRewardPerShare;
        uint256 totalStakedAddress;
        uint256 totalAmount;
    }

    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    mapping (uint256 => mapping (address => bool)) public isStakedAddress;

    IKISS public KISS;
    uint256 public singleShare = 20;
    uint256 public lpShare = 80;
    uint256 public singleAllocPoints = 0;
    uint256 public lpAllocPoints = 0;
    uint256 public singleReleaseTime = 20 hours;
    uint256 public lpReleaseTime = 10 hours;
    uint256 public startTime;
    uint256 public reduceStartTime;
    uint256 public constant MAX_RELEASE_TIME = 24 hours;
    uint256 public constant REDUCE_PERIOD = 365 days / 4;
    uint256 public constant RESERVE_PRECENTAGE = 89;
    // uint256 public constant INIT_REWARD_PER_SEC = 22330000e18 / REDUCE_PERIOD * 10 / 11;
    uint256 public constant BONUS_PERIOD = 14 days;
    // uint256 public constant BONUS_REWARD_PER_SEC = 7000000e18 / BONUS_PERIOD * 10 / 11;
    uint256 public constant MAX_FEE = 1e18;
    uint256 public singleDepositFee = 1e17;
    bool public singleDepositFeeOn = true;
    uint256 public singleWithdrawFee = 1e17;
    bool public singleWithdrawFeeOn = true;
    uint256 public singleReleaseFee = 1e17;
    bool public singleReleaseFeeOn = true;
    uint256 public lpDepositFee = 0;
    bool public lpDepositFeeOn = false;
    uint256 public lpWithdrawFee = 1e17;
    bool public lpWithdrawFeeOn = true;
    uint256 public lpReleaseFee = 0;
    bool public lpReleaseFeeOn = false;
    address payable public devaddr;
    address payable public feeAddr;
    mapping(address => uint256) public pidOfPool;
    address public keeper;
    
    constructor(IKISS _KISS, address payable _devaddr, address payable _feeAddr, uint256 _startTime) public {
        require(_startTime > block.timestamp, "KISSPools: Incorrect start time");
        KISS = _KISS;
        devaddr = _devaddr;
        feeAddr = _feeAddr;
        startTime = _startTime;
        reduceStartTime = startTime + BONUS_PERIOD;
        keeper = msg.sender;
    }
    
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }
    
    function phase(uint256 _timestamp) public view returns (uint256) {
        if (_timestamp > reduceStartTime) {
            return (_timestamp.sub(reduceStartTime).sub(1)).div(REDUCE_PERIOD) + 1;
        }
        return 0;
    }

    function reward(uint256 _timestamp) public view returns (uint256) {
        (uint256 maxMint,) = KISS.getMintInfo(address(this));
        if (_timestamp <= reduceStartTime) {
            // maxMint * 7000000e18 / 210000000e18 / BONUS_PERIOD * 10 / 11
            return maxMint / 33 / BONUS_PERIOD;
            // return BONUS_REWARD_PER_SEC;
        }
        uint256 _phase = phase(_timestamp);
        // uint256 periodReward = INIT_REWARD_PER_SEC;
        // maxMint * 22330000e18 / 210000000e18 / REDUCE_PERIOD * 10 / 11
        uint256 periodReward = maxMint * 29 / 300 / REDUCE_PERIOD;
        for (uint256 i = 1; i < _phase; i++) {
            periodReward = periodReward.mul(RESERVE_PRECENTAGE).div(100);
        }
        return periodReward;
    }
    
    function getPoolsReward(uint256 _lastRewardTime, uint256 _currentTime) public view returns (uint256) {
        uint256 poolsReward = 0;
        uint256 n = phase(_lastRewardTime);
        uint256 m = phase(_currentTime);
        if (n == 0 && n < m) {
            uint256 r = BONUS_PERIOD.add(startTime);
            poolsReward = poolsReward.add((r.sub(_lastRewardTime)).mul(reward(r)));
            _lastRewardTime = r;
            n++;
        }
        while (n < m) {
            uint256 r = n.mul(REDUCE_PERIOD).add(reduceStartTime);
            poolsReward = poolsReward.add((r.sub(_lastRewardTime)).mul(reward(r)));
            _lastRewardTime = r;
            n++;
        }
        poolsReward = poolsReward.add((_currentTime.sub(_lastRewardTime)).mul(reward(_currentTime)));
        return poolsReward;
    }
    
    function _getPoolReward(uint256 _poolsReward, uint256 _allocPoint, POOL_TYPE _poolType)  internal view returns (uint256) {
        if (_poolType == POOL_TYPE.Single) {
            return singleAllocPoints == 0 ? 0 : _poolsReward.mul(singleShare).div(100).mul(_allocPoint).div(singleAllocPoints);
        } else {
            return lpAllocPoints == 0 ? 0 : _poolsReward.mul(lpShare).div(100).mul(_allocPoint).div(lpAllocPoints);
        }
    }
    
    function pendingReword(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 stakedTokenSupply = pool.totalAmount;
        if (user.amount > 0) {
            if (block.timestamp > pool.lastRewardTime) {
                uint256 poolsReward = getPoolsReward(pool.lastRewardTime, block.timestamp);
                uint256 poolReward = _getPoolReward(poolsReward, pool.allocPoint, pool.poolType);
                accRewardPerShare = accRewardPerShare.add(poolReward.mul(1e12).div(stakedTokenSupply));
                return user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt).add(user.tempReward);
            }
            if (block.timestamp == pool.lastRewardTime) {
                return user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt).add(user.tempReward);
            }
        }
        return 0;
    }
    
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        
        if (pool.totalAmount == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        
        uint256 stakedTokenSupply = pool.totalAmount;
        uint256 poolsReward = getPoolsReward(pool.lastRewardTime, block.timestamp);
        if (poolsReward <= 0) {
            return;
        }
        uint256 poolReward = _getPoolReward(poolsReward, pool.allocPoint, pool.poolType);
        (uint256 maxMint, uint256 nowMint) = KISS.getMintInfo(address(this));
        uint256 remaining = maxMint.sub(nowMint);

        if (remaining > 0) {
            if (poolReward.add(poolReward.div(10)) < remaining) {
                KISS.mint(devaddr, poolReward.div(10));
                KISS.mint(address(this), poolReward);
                pool.accRewardPerShare = pool.accRewardPerShare.add(poolReward.mul(1e12).div(stakedTokenSupply));
                emit Mint(poolReward);
            } else {
                uint256 devReward = remaining.div(11);
                KISS.mint(devaddr, devReward);
                KISS.mint(address(this), remaining.sub(devReward));
                pool.accRewardPerShare = pool.accRewardPerShare.add(remaining.sub(devReward).mul(1e12).div(stakedTokenSupply));
                emit Mint(remaining.sub(devReward));
            }
        }
        
        pool.lastRewardTime = block.timestamp;
    }
    
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }
    
    function isReleased(uint256 _pid, address _user) public view returns (bool) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        uint256 releaseTime = pool.poolType == POOL_TYPE.Single ? singleReleaseTime : lpReleaseTime;
        return user.harvestTime.add(releaseTime) < block.timestamp;
    }
    
    function withdrawReleased(uint256 _pid) external payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && singleReleaseFeeOn) {
            require(msg.value == singleReleaseFee, "KISSPools: none release fee");
            feeAddr.transfer(address(this).balance);
        } else if (pool.poolType == POOL_TYPE.LP && lpReleaseFeeOn) {
            require(msg.value == lpReleaseFee, "KISSPools: none release fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        uint256 releaseTime = pool.poolType == POOL_TYPE.Single ? singleReleaseTime : lpReleaseTime;
        uint256 newRelease = user.harvestAmount.mul(block.timestamp.sub(user.releasedTime)).div(releaseTime);
        newRelease = newRelease > user.leftAmount ? user.leftAmount : newRelease;
        uint256 releaseAmount = user.releasedAmount.add(newRelease);
        user.leftAmount = user.leftAmount.sub(newRelease);
        user.releasedAmount = 0;
        user.releasedTime = block.timestamp;
        require(releaseAmount > 0, "KISSPools: no released reward");
        _safeRewardTransfer(_user, releaseAmount);
        emit WithdrawReleased(_user, _pid, releaseAmount);
    }
    
    function deposit(uint256 _pid, uint256 _amount) external payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && singleDepositFeeOn) {
            require(msg.value == singleDepositFee, "KISSPools: none deposit fee");
            feeAddr.transfer(address(this).balance);
        } else if (pool.poolType == POOL_TYPE.LP && lpDepositFeeOn) {
            require(msg.value == lpDepositFee, "KISSPools: none deposit fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pendingAmount = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if (pendingAmount > 0) {
                user.tempReward = user.tempReward.add(pendingAmount);
            }
        }
        if (_amount > 0) {
            pool.stakedToken.safeTransferFrom(_user, address(this), _amount);
            user.amount = user.amount.add(_amount);
            pool.totalAmount = pool.totalAmount.add(_amount);
            if (!isStakedAddress[_pid][_user]) {
                isStakedAddress[_pid][_user] = true;
                pool.totalStakedAddress = pool.totalStakedAddress.add(1);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }
    
    function withdraw(uint256 _pid, uint256 _amount) external payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && singleWithdrawFeeOn) {
            require(msg.value == singleWithdrawFee, "KISSPools: none withdraw fee");
            feeAddr.transfer(address(this).balance);
        } else if (pool.poolType == POOL_TYPE.LP && lpWithdrawFeeOn) {
            require(msg.value == lpWithdrawFee, "KISSPools: none withdraw fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        require(user.amount >= _amount, "KISSPools: Insuffcient amount to withdraw");
        updatePool(_pid);
        uint256 pendingAmount = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt).add(user.tempReward);
        if (pendingAmount > 0) {
            require(isReleased(_pid, _user), "KISSPools: must wait until last released");
            user.tempReward = 0;
            user.harvestAmount = pendingAmount;
            user.releasedAmount = user.releasedAmount.add(user.leftAmount);
            user.leftAmount = pendingAmount;
            user.harvestTime = block.timestamp;
            user.releasedTime = block.timestamp;
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalAmount = pool.totalAmount.sub(_amount);
            pool.stakedToken.safeTransfer(_user, _amount);
            if (user.amount == 0) {
                isStakedAddress[_pid][_user] = false;
                pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Withdraw(_user, _pid, _amount);
    }
    
    function emergencyWithdraw(uint256 _pid) external payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.poolType == POOL_TYPE.Single && singleWithdrawFeeOn) {
            require(msg.value == singleWithdrawFee, "KISSPools: none withdraw fee");
            feeAddr.transfer(address(this).balance);
        } else if (pool.poolType == POOL_TYPE.LP && lpWithdrawFeeOn) {
            require(msg.value == lpWithdrawFee, "KISSPools: none withdraw fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.harvestAmount = 0;
        user.harvestTime = 0;
        user.leftAmount = 0;
        user.releasedAmount = 0;
        user.releasedTime = 0;
        user.tempReward = 0;
        pool.stakedToken.safeTransfer(_user, amount);
        pool.totalAmount = pool.totalAmount.sub(amount);
        isStakedAddress[_pid][_user] = false;
        pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
        emit EmergencyWithdraw(_user, _pid, amount);
    }
    
    function getPoolReward(uint256 _pid, uint256 _duration) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 poolsReward = getPoolsReward(block.timestamp, block.timestamp + _duration);
        uint256 poolReward = _getPoolReward(poolsReward, pool.allocPoint, pool.poolType);
        return poolReward;
    }
    
    function addPool(POOL_TYPE _poolType, uint256 _allocPoint, IERC20 _stakedToken, bool _withUpdate) public  onlyOwner {
        require(address(_stakedToken) != address(0), "KISSPools: zero pool address");
        require(poolInfo.length == 0 || (pidOfPool[address(_stakedToken)] == 0 && poolInfo[0].stakedToken != _stakedToken), "KISSPools: pool added");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        if (_poolType == POOL_TYPE.Single) {
            singleAllocPoints = singleAllocPoints.add(_allocPoint);
        } else {
            lpAllocPoints = lpAllocPoints.add(_allocPoint);
        }
        poolInfo.push(PoolInfo({
            poolType: _poolType,
            stakedToken: _stakedToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accRewardPerShare: 0,
            totalAmount: 0,
            totalStakedAddress: 0
        }));
        pidOfPool[address(_stakedToken)] = poolInfo.length - 1;
        emit PoolAdded(_poolType, address(_stakedToken), _allocPoint);
    }
    
    function setPool(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        require(_pid < poolInfo.length, "KISSPools: pool not exist");
        if (_withUpdate) {
            massUpdatePools();
        }
        if (poolInfo[_pid].poolType == POOL_TYPE.Single) {
            singleAllocPoints = singleAllocPoints.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        } else {
            lpAllocPoints = lpAllocPoints.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        }
        poolInfo[_pid].allocPoint = _allocPoint;
        emit PoolSetted(address(poolInfo[_pid].stakedToken), _allocPoint);
    }
    
    function _safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 rewardBal = KISS.balanceOf(address(this));
        if (_amount > rewardBal) {
            IERC20(KISS).safeTransfer(_to, rewardBal);
        } else {
            IERC20(KISS).safeTransfer(_to, _amount);
        }
    }
    
    function getPools() external view onlyOwner returns (PoolInfo[] memory) {
        return poolInfo;
    }
    
    function batchAddPools(IERC20[] calldata _stakedTokens, uint256[] calldata _allocPoints, POOL_TYPE[] calldata _poolTypes, bool _withUpdate) external onlyOwner {
        require(_stakedTokens.length == _allocPoints.length && _stakedTokens.length == _poolTypes.length, "KISSPools: Invalid length of pools");
        for(uint i = 0; i < _stakedTokens.length; i++) {
            addPool(_poolTypes[i], _allocPoints[i], _stakedTokens[i], _withUpdate);
        }
    }
    
    function batchSetPoolsByStakedToken(IERC20[] calldata _stakedTokens, uint256[] calldata _allocPoints, bool _withUpdate) external onlyOwner {
        require(_stakedTokens.length == _allocPoints.length, "KISSPools: Invalid length of pools");
        for(uint i = 0; i < _stakedTokens.length; i++) {
            setPool(pidOfPool[address(_stakedTokens[i])], _allocPoints[i], _withUpdate);
        }
    }
    
    function setPoolShare(uint256 _single, uint256 _lp) external {
        require(msg.sender == keeper, "KISSPools:keeper permit");
        require(_single.add(_lp) == 100, "KISSPools: the sum of two share should be 100");
        singleShare = _single;
        lpShare = _lp;
    }
    
    function setDevAddr(address payable _devaddr) external onlyOwner {
        devaddr = _devaddr;
    }
    
    function setFeeAddr(address payable _feeAddr) external onlyOwner{
        feeAddr = _feeAddr;
    }
    
    function setSingleDepositFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "KISSPools: max fee");
        singleDepositFeeOn = (_fee != 0);
        singleDepositFee = _fee;
    }
    
    function setSingleWithdrawFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "KISSPools: max fee");
        singleWithdrawFeeOn = (_fee != 0);
        singleWithdrawFee = _fee;
    }
    
    function setSingleReleaseFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "KISSPools: max fee");
        singleReleaseFeeOn = (_fee != 0);
        singleReleaseFee = _fee;
    }
    
    function setLPDepositFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "KISSPools: max fee");
        lpDepositFeeOn = (_fee != 0);
        lpDepositFee = _fee;
    }
    
    function setLPWithdrawFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "KISSPools: max fee");
        lpWithdrawFeeOn = (_fee != 0);
        lpWithdrawFee = _fee;
    }
    
    function setLPReleaseFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "KISSPools: max fee");
        lpReleaseFeeOn = (_fee != 0);
        lpReleaseFee = _fee;
    }
    
    function setSingleReleaseTime(uint256 _time) external onlyOwner {
        require(_time > 0 && _time <= MAX_RELEASE_TIME, "KISSPools: invalid release time");
        singleReleaseTime = _time;
    }
    
    function setLPReleaseTime(uint256 _time) external onlyOwner {
        require(_time > 0 && _time <= MAX_RELEASE_TIME, "KISSPools: invalid release time");
        lpReleaseTime = _time;
    }
    
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }
}