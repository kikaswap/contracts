pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;
import "../openzeppelin/contracts/access/Ownable.sol";
import "../openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interface/IKISS.sol";
import "../interface/IUniswapV2Pair.sol";

interface IOracle {
    function getQuantity(address outputToken, uint256 outputAmount, address anchorToken) external view returns (uint256);
}

contract KISSPools is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Mint(uint256 amount);
    event PoolAdded(POOL_TYPE poolType, address indexed stakedToken, address indexed stakedToken2, uint256 allocPoint);
    event PoolSetted(address indexed stakedToken, address indexed stakedToken2, uint256 allocPoint);
    event WithdrawReleased(address indexed user, uint256 indexed pid, uint256 amount);

    enum POOL_TYPE { Single, LP, DUAL }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 harvestAmount;
        uint256 harvestTime;
        uint256 releasedAmount;
        uint256 releasedTime;
        uint256 leftAmount;
        uint256 tempReward;
        uint256 amount2;
    }

    struct PoolInfo {
        POOL_TYPE poolType;
        IERC20 stakedToken;
        IERC20 stakedToken2;
        uint256 allocPoint;
        uint256 token2Rate;
        uint256 lastRewardTime;
        uint256 accRewardPerShare;
        uint256 totalStakedAddress;
        uint256 totalAmount;
        uint256 totalAmount2;
    }
    
    struct PoolConfig {
        uint256 share;
        uint256 allocPoints;
        uint256 releaseTime;
        uint256 depositFee;
        uint256 withdrawFee;
        uint256 releaseFee;
        uint256 feeRate;
    }

    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    mapping (uint256 => mapping (address => bool)) public isStakedAddress;
    IKISS public KISS;
    uint256 public startTime;
    uint256 public reduceStartTime;
    uint256 public constant MAX_RELEASE_TIME = 24 hours;
    uint256 public constant REDUCE_PERIOD = 365 days / 4;
    uint256 public constant RESERVE_PRECENTAGE = 89;
    uint256 public constant BONUS_PERIOD = 14 days;
    uint256 public constant MAX_FEE = 1e18;
    uint256 public constant MAX_FEERATE = 10;
    uint256 public constant BLIND_PERIOD = 163 hours;
    address public devAddr;
    address public servAddr;
    address payable public feeAddr;
    mapping(address => mapping(address => uint256)) public pidOfPool;
    mapping(POOL_TYPE => PoolConfig) public poolConfig;
    address public oracle;
    
    constructor(IKISS _KISS, address _devAddr, address payable _feeAddr, address _servAddr, uint256 _startTime, address _oracle) public {
        require(_startTime > block.timestamp, "KISSPools: Incorrect start time");
        KISS = _KISS;
        devAddr = _devAddr;
        feeAddr = _feeAddr;
        servAddr = _servAddr;
        startTime = _startTime;
        reduceStartTime = startTime + BONUS_PERIOD;
        oracle = _oracle;
        setPoolConfig(POOL_TYPE.Single, 20 hours, 1e17, 1e17, 1e17, 3);
        setPoolConfig(POOL_TYPE.LP, 10 hours, 0, 0, 0, 0);
        setPoolConfig(POOL_TYPE.DUAL, 20 hours, 0, 0, 0, 0);
        setPoolShare(10, 90, 0);
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
            return maxMint * 3 / 100 / BONUS_PERIOD; // maxMint*(1/30)*(9/10)
        }
        uint256 _phase = phase(_timestamp);
        uint256 periodReward = maxMint * 957 / 10000 / REDUCE_PERIOD; // maxMint*(29/30)*(11/100)*(9/10)
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
        PoolConfig memory config = poolConfig[_poolType];
        return config.allocPoints == 0 ? 0 : _poolsReward.mul(config.share).div(100).mul(_allocPoint).div(config.allocPoints);
    }
    
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
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
        
        uint256 poolsReward = getPoolsReward(pool.lastRewardTime, block.timestamp);
        if (poolsReward <= 0) {
            return;
        }
        uint256 poolReward = _getPoolReward(poolsReward, pool.allocPoint, pool.poolType);
        (uint256 maxMint, uint256 nowMint) = KISS.getMintInfo(address(this));
        uint256 remaining = maxMint.sub(nowMint);

        if (remaining > 0) {
            if (poolReward.add(poolReward.div(9)) < remaining) {
                KISS.mint(devAddr, poolReward.div(9));
                KISS.mint(address(this), poolReward);
                pool.accRewardPerShare = pool.accRewardPerShare.add(poolReward.mul(1e12).div(pool.totalAmount));
                emit Mint(poolReward);
            } else {
                uint256 devReward = remaining.div(10);
                KISS.mint(devAddr, devReward);
                KISS.mint(address(this), remaining.sub(devReward));
                pool.accRewardPerShare = pool.accRewardPerShare.add(remaining.sub(devReward).mul(1e12).div(pool.totalAmount));
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
    
    function dualPoolQuantity(uint256 _pid, uint256 _amount) public view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        if (pool.poolType != POOL_TYPE.DUAL) {
            return 0;
        }
        uint256 quantity = IOracle(oracle).getQuantity(address(pool.stakedToken), _amount, address(pool.stakedToken2));
        return quantity.mul(pool.token2Rate).div(100);
    }
    
    function deposit(uint256 _pid, uint256 _amount) external payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        PoolConfig memory config = poolConfig[pool.poolType];
        if (config.depositFee > 0) {
            require(msg.value == config.depositFee, "KISSPools: none deposit fee");
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
            if (config.feeRate > 0) {
                uint256 servAmount = _amount.mul(config.feeRate).div(1000);
                if (servAmount > 0) {
                    pool.stakedToken.safeTransfer(servAddr, servAmount);
                    _amount = _amount.sub(servAmount);
                }
            }
            user.amount = user.amount.add(_amount);
            pool.totalAmount = pool.totalAmount.add(_amount);
            if (pool.poolType == POOL_TYPE.DUAL) {
                uint256 amount2 = dualPoolQuantity(_pid, _amount);
                if (amount2 > 0) {
                    pool.stakedToken2.safeTransferFrom(_user, address(this), amount2);
                    user.amount2 = user.amount2.add(amount2);
                    pool.totalAmount2 = pool.totalAmount2.add(amount2);
                }
            }
            if (!isStakedAddress[_pid][_user]) {
                isStakedAddress[_pid][_user] = true;
                pool.totalStakedAddress = pool.totalStakedAddress.add(1);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }
    
    function withdraw(uint256 _pid, uint256 _amount) external payable nonReentrant {
        require(block.timestamp > startTime + BLIND_PERIOD, "KISSPools: in BLIND_PERIOD");
        PoolInfo storage pool = poolInfo[_pid];
        PoolConfig memory config = poolConfig[pool.poolType];
        if (config.withdrawFee > 0) {
            require(msg.value == config.withdrawFee, "KISSPools: none withdraw fee");
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
            if (pool.poolType == POOL_TYPE.DUAL) {
                uint256 amount2 = user.amount == _amount ? user.amount2 : user.amount2.mul(_amount).div(user.amount);
                if (amount2 > 0) {
                    user.amount2 = user.amount2.sub(amount2);
                    pool.totalAmount2 = pool.totalAmount2.sub(amount2);
                    pool.stakedToken2.safeTransfer(_user, amount2);
                }
            }
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
        PoolConfig memory config = poolConfig[pool.poolType];
        if (config.withdrawFee > 0) {
            require(msg.value == config.withdrawFee, "KISSPools: none withdraw fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        uint256 amount = user.amount;
        uint256 amount2 = user.amount2;
        user.amount = 0;
        user.rewardDebt = 0;
        user.harvestAmount = 0;
        user.harvestTime = 0;
        user.leftAmount = 0;
        user.releasedAmount = 0;
        user.releasedTime = 0;
        user.tempReward = 0;
        user.amount2 = 0;
        isStakedAddress[_pid][_user] = false;
        if (amount > 0) {
            pool.totalAmount = pool.totalAmount.sub(amount);
            pool.stakedToken.safeTransfer(_user, amount2);
            pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
        }
        if (amount2 > 0) {
            pool.totalAmount2 = pool.totalAmount2.sub(amount2);
            pool.stakedToken2.safeTransfer(_user, amount2);
        }
        emit EmergencyWithdraw(_user, _pid, amount);
    }
    
    function isReleased(uint256 _pid, address _user) public view returns (bool) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        PoolConfig memory config = poolConfig[pool.poolType];
        return user.harvestTime.add(config.releaseTime) < block.timestamp;
    }
    
    function withdrawReleased(uint256 _pid) external payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        PoolConfig memory config = poolConfig[pool.poolType];
        if (config.releaseFee > 0) {
            require(msg.value == config.releaseFee, "KISSPools: none release fee");
            feeAddr.transfer(address(this).balance);
        }
        address _user = msg.sender;
        UserInfo storage user = userInfo[_pid][_user];
        uint256 newRelease = user.harvestAmount.mul(block.timestamp.sub(user.releasedTime)).div(config.releaseTime);
        newRelease = newRelease > user.leftAmount ? user.leftAmount : newRelease;
        uint256 releaseAmount = user.releasedAmount.add(newRelease);
        user.leftAmount = user.leftAmount.sub(newRelease);
        user.releasedAmount = 0;
        user.releasedTime = block.timestamp;
        require(releaseAmount > 0, "KISSPools: no released reward");
        _safeRewardTransfer(_user, releaseAmount);
        emit WithdrawReleased(_user, _pid, releaseAmount);
    }
    
    function getPoolReward(uint256 _pid, uint256 _duration) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 poolsReward = getPoolsReward(block.timestamp, block.timestamp + _duration);
        uint256 poolReward = _getPoolReward(poolsReward, pool.allocPoint, pool.poolType);
        return poolReward;
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
    
    modifier validPoolType(POOL_TYPE poolType){
        require(poolType <= POOL_TYPE.DUAL, "KISSPools: invalid pooltype");
        _;
    }
    
    function addPool(POOL_TYPE _poolType, uint256 _allocPoint, IERC20 _stakedToken, IERC20 _stakedToken2, uint256 _token2Rate, bool _withUpdate) public  onlyOwner validPoolType(_poolType) {
        require(address(_stakedToken) != address(0), "KISSPools: zero pool address");
        if (_poolType != POOL_TYPE.DUAL){
            _stakedToken2 = IERC20(0);
            _token2Rate = 0;
        } else {
            require(address(_stakedToken2) != address(0), "KISSPools: zero pool address2");
        }
        require(poolInfo.length == 0 || (pidOfPool[address(_stakedToken2)][address(_stakedToken)] == 0 && (poolInfo[0].stakedToken != _stakedToken || poolInfo[0].stakedToken2 != _stakedToken2)), "KISSPools: pool added");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        PoolConfig storage config = poolConfig[_poolType];
        config.allocPoints = config.allocPoints.add(_allocPoint);
        pidOfPool[address(_stakedToken2)][address(_stakedToken)] = poolInfo.length;
        poolInfo.push(PoolInfo({
            poolType: _poolType,
            stakedToken: _stakedToken,
            stakedToken2:_stakedToken2,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            token2Rate: _token2Rate,
            accRewardPerShare: 0,
            totalAmount: 0,
            totalStakedAddress: 0,
            totalAmount2:0
        }));
        emit PoolAdded(_poolType, address(_stakedToken), address(_stakedToken2), _allocPoint);
    }
    
    function setPool(uint256 _pid, uint256 _allocPoint, uint256 _token2Rate,  bool _withUpdate) public onlyOwner {
        require(_pid < poolInfo.length, "KISSPools: pool not exist");
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolConfig storage config = poolConfig[poolInfo[_pid].poolType];
        config.allocPoints = config.allocPoints.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].token2Rate = _token2Rate;
        emit PoolSetted(address(poolInfo[_pid].stakedToken), address(poolInfo[_pid].stakedToken2), _allocPoint);
    }
    
    function addPools(POOL_TYPE[] calldata _poolType, uint256[] calldata _allocPoint, IERC20[] calldata _stakedToken, IERC20[] calldata _stakedToken2, uint256[] calldata _token2Rate, bool _withUpdate) external {
        require(_poolType.length == _allocPoint.length && _poolType.length == _stakedToken.length && _poolType.length == _stakedToken2.length && _poolType.length == _token2Rate.length, "KISSPools: length not match");
        for (uint256 i = 0; i < _poolType.length; i++) {
            addPool(_poolType[i],_allocPoint[i],_stakedToken[i],_stakedToken2[i],_token2Rate[i],_withUpdate);
        }
    }
    
    function setPools(uint256[] calldata _pid, uint256[] calldata _allocPoint, uint256[] calldata _token2Rate,  bool _withUpdate) external {
        require(_pid.length == _allocPoint.length && _pid.length == _token2Rate.length, "KISSPools: length not match");
        for (uint256 i = 0; i < _pid.length; i++) {
            setPool(_pid[i],_allocPoint[i],_token2Rate[i],_withUpdate);
        }
    }
    
    function setPoolShare(uint256 _single, uint256 _lp, uint256 _dual) public onlyOwner {
        require(_single.add(_lp).add(_dual) == 100, "KISSPools: the sum of two share should be 100");
        poolConfig[POOL_TYPE.Single].share = _single;
        poolConfig[POOL_TYPE.LP].share = _lp;
        poolConfig[POOL_TYPE.DUAL].share = _dual;
    }
    
    function setDevAddr(address _devAddr) external onlyOwner {
        devAddr = _devAddr;
    }
    
    function setFeeAddr(address payable _feeAddr) external onlyOwner{
        feeAddr = _feeAddr;
    }
    
    function setServAddr(address _servAddr) external onlyOwner{
        servAddr = _servAddr;
    }
    
    function setOracle(address _oracle) external onlyOwner{
        oracle = _oracle;
    }
    
    function setPoolConfig(POOL_TYPE _poolType, uint256 _releaseTime, uint256 _depositFee, uint256 _withdrawFee, uint256 _releaseFee, uint256 _feeRate) public onlyOwner validPoolType(_poolType) {
        require(_releaseTime > 0 && _releaseTime <= MAX_RELEASE_TIME, "KISSPools: invalid releaseTime");
        require(_depositFee <= MAX_FEE, "KISSPools: invalid depositFee");
        require(_withdrawFee <= MAX_FEE, "KISSPools: invalid withdrawFee");
        require(_releaseFee <= MAX_FEE, "KISSPools: invalid releaseFee");
        require(_feeRate <= MAX_FEERATE, "KISSPools: invalid feeRate");
        poolConfig[_poolType].releaseTime = _releaseTime;
        poolConfig[_poolType].depositFee = _depositFee;
        poolConfig[_poolType].withdrawFee = _withdrawFee;
        poolConfig[_poolType].releaseFee = _releaseFee;
        poolConfig[_poolType].feeRate = _feeRate;
    }
}