pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;
import "../openzeppelin/contracts/access/Ownable.sol";
import "../openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../openzeppelin/contracts/utils/EnumerableSet.sol";
import "../openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract KISSBoardroom is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount, uint256 indexed lockedId, uint256 penlaty);
    event RewardTokenAdded(address indexed rewardToken, uint256 decimals, uint256 rid);
    
    struct LockedInfo {
        uint256 amount;
        uint256 stakedTime;
        uint256 expireTime;
        uint256 unlockTime;
        bool isWithdrawed;
    }
    
    struct UserInfo {
        uint256 totalAmount;
        mapping (uint256 => uint256) rewardDebt; 
        LockedInfo[] lockedInfo;
    }
    
    struct PoolInfo {
        IERC20 stakedToken;
        mapping (uint256 => uint256) lastRewardTime;
        mapping (uint256 => uint256) accRewardPerShare;
        uint256 totalAmount;
        uint256 totalStakedAddress;
    }

    struct RewardTokenInfo {
        IERC20 rewardToken;
        string symbol;
        uint256 decimals;
        uint256 magicNumber;
        uint256 startTime;
        uint256 endTime;
        uint256 rewardPerSec;
        uint256 tokenRemaining;
        uint256 tokenRewarded;
        uint256 rid;
    }
    
    RewardTokenInfo[] public rewardTokenInfo;
    PoolInfo public poolInfo;
    mapping (address => UserInfo) public userInfo;
    mapping (address => bool) public isStakedAddress;
    uint256 public rewardPeriod = 7 days;
    uint256 public lockedTime = 30 days;
    uint256 public minLockTime = 10 days;
    uint256 public midLockTime = 20 days;
    uint256 public minPenalty = 30;
    uint256 public midPenalty = 50;
    uint256 public maxPenalty = 80;
    bool public minPenaltyOn = true;
    bool public midPenaltyOn = true;
    bool public maxPenaltyOn = false;
    mapping(address => uint256) public ridOfReward;
    mapping(uint256 => address) public setterOfRid;
    mapping(address => bool) public isExistedRewardToken;
    EnumerableSet.AddressSet private _setter;
    address public BLACK_HOLE;
    uint256 public constant MAX_REWOARD_TOKEN = 30;
    uint256 public constant MAX_LOCK_TIME = 30 days;
    uint256 public constant MAX_REWARD_PERIOD = 30 days;

    modifier onlySetter() {
        require(isSetter(msg.sender), "KISSBoardroom: Not the setter");
        _;
    }
    
    constructor(address _blackHole, IERC20 _stakedToken) public {
        BLACK_HOLE = _blackHole;
        EnumerableSet.add(_setter, msg.sender);
        poolInfo.stakedToken = _stakedToken;
    }

    function getSetterLength() public view returns (uint256) {
        return EnumerableSet.length(_setter);
    }

    function isSetter(address _set) public view returns (bool) {
        return EnumerableSet.contains(_setter, _set);
    }

    function getSetter(uint256 _index) public view returns (address){
        require(_index <= getSetterLength() - 1, "KISSBoardroom: index out of bounds");
        return EnumerableSet.at(_setter, _index);
    }
    
    function getRewardTokenInfo() external view returns(RewardTokenInfo[] memory) {
        return rewardTokenInfo;
    }
    
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }
    
    function getUserLockedInfo(address _user) public view returns(LockedInfo[] memory) {
        UserInfo memory user = userInfo[_user];
        return user.lockedInfo;
    }
    
    function getUserLockedAmount(address _user) public view returns(uint256) {
        UserInfo memory user = userInfo[_user];
        LockedInfo[] memory lockedInfo = user.lockedInfo;
        uint256 lockedAmount = 0;
        for(uint i = 0; i < lockedInfo.length; i++) {
            if (lockedInfo[i].expireTime > block.timestamp && !lockedInfo[i].isWithdrawed) {
                lockedAmount = lockedAmount.add(lockedInfo[i].amount);
            }
        }
        return lockedAmount;
    }
    
    function pendingRewards(uint256 _rid, address _user) external view returns(uint256) {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[_user];
        RewardTokenInfo storage token = rewardTokenInfo[_rid];
        uint256 accRewardPerShare = pool.accRewardPerShare[_rid];
        uint256 lastRewardTime = pool.lastRewardTime[_rid];
        uint256 stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        if (block.timestamp > lastRewardTime && stakedTokenSupply != 0) {
            uint256 multiplier = getMultiplier(lastRewardTime, block.timestamp);
            uint256 tokenReward = multiplier.mul(token.rewardPerSec);
            if (tokenReward > token.tokenRemaining) {
                tokenReward = token.tokenRemaining;
            }
            accRewardPerShare = accRewardPerShare.add(tokenReward.mul(token.magicNumber).div(stakedTokenSupply));
        }
        return user.totalAmount.mul(accRewardPerShare).div(token.magicNumber).sub(user.rewardDebt[_rid]);
    }
    
    function updatePool(uint256 _rid) public {
        PoolInfo storage pool = poolInfo;
        RewardTokenInfo storage token = rewardTokenInfo[_rid];
        uint256 lastRewardTime = pool.lastRewardTime[_rid];
        
        if (block.timestamp <= lastRewardTime) {
            return;
        }
        
        uint256 stakedTokenSupply = pool.stakedToken.balanceOf(address(this));
        if (stakedTokenSupply == 0 || token.tokenRemaining == 0) {
            pool.lastRewardTime[_rid] = block.timestamp;
            return;
        }

        uint256 multiplier = getMultiplier(lastRewardTime, block.timestamp);
        uint256 tokenReward = multiplier.mul(token.rewardPerSec);
        if (tokenReward > token.tokenRemaining) {
            tokenReward = token.tokenRemaining;
            token.tokenRemaining = 0;
        } else {
            token.tokenRemaining = token.tokenRemaining.sub(tokenReward);
        }
        token.tokenRewarded = token.tokenRewarded.add(tokenReward);
        pool.accRewardPerShare[_rid] = pool.accRewardPerShare[_rid].add(tokenReward.mul(token.magicNumber).div(stakedTokenSupply));
        pool.lastRewardTime[_rid] = block.timestamp;
    }
    
    function massUpdatePools() public {
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            updatePool(rid);
        }
    }
    
    function deposit(uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo;
        address _user = msg.sender;
        UserInfo storage user = userInfo[_user];
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            updatePool(rid);
            if (user.totalAmount > 0) {
                uint256 pending = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber).sub(user.rewardDebt[rid]);
                if(pending > 0) {
                    _safeTokenTransfer(rewardTokenInfo[rid].rewardToken, msg.sender, pending);
                }
            }
        }
        if(_amount > 0) {
            pool.stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.totalAmount = user.totalAmount.add(_amount); 
            pool.totalAmount = pool.totalAmount.add(_amount);
            user.lockedInfo.push(LockedInfo(
                _amount,
                block.timestamp,
                block.timestamp.add(lockedTime),
                0,
                false
            ));
            if (!isStakedAddress[_user]) {
                isStakedAddress[_user] = true;
                pool.totalStakedAddress = pool.totalStakedAddress.add(1);
            }
        }
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            user.rewardDebt[rid] = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber);
        }
        emit Deposit(msg.sender, _amount);
    }
    
    function withdraw(uint256 _lockedId) external {
        _withdraw(_lockedId, true);
    }
    
    function emergencyWithdraw(uint256 _lockedId) external {
        _withdraw(_lockedId, false);
    }
    
    function _withdraw(uint256 _lockedId, bool _withReward) internal nonReentrant {
        PoolInfo storage pool = poolInfo;
        address _user = msg.sender;
        UserInfo storage user = userInfo[_user];
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            updatePool(rid);
            if (user.totalAmount > 0 && _withReward) {
                uint256 pending = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber).sub(user.rewardDebt[rid]);
                if(pending > 0) {
                    _safeTokenTransfer(rewardTokenInfo[rid].rewardToken, msg.sender, pending);
                }
            }
        }
        uint256 penlaty = 0;
        uint256 _amount = user.lockedInfo[_lockedId].amount;
        if (_amount > 0) {
            require(!user.lockedInfo[_lockedId].isWithdrawed, "KISSBoardroom: This amount of lockedId is withdrawed");
            uint256 expireTime = user.lockedInfo[_lockedId].expireTime;
            uint256 stakedTime = user.lockedInfo[_lockedId].stakedTime;
            if (expireTime < block.timestamp) {
                pool.stakedToken.safeTransfer(address(msg.sender), _amount);
            } else {
                uint256 interval = block.timestamp.sub(stakedTime);
                if (interval <= minLockTime) {
                    require(maxPenaltyOn, "KISSBoardroom: maxLockTime");
                    penlaty = _amount.mul(maxPenalty).div(100);
                } else if (interval <= midLockTime) {
                    require(midPenaltyOn, "KISSBoardroom: midLockTime");
                    penlaty = _amount.mul(midPenalty).div(100);
                } else {
                    require(minPenaltyOn, "KISSBoardroom: minLockTime");
                    penlaty = _amount.mul(minPenalty).div(100);
                }
                pool.stakedToken.safeTransfer(address(msg.sender), _amount.sub(penlaty));
                pool.stakedToken.safeTransfer(BLACK_HOLE, penlaty);
            }
            user.lockedInfo[_lockedId].unlockTime = block.timestamp;
            user.totalAmount = user.totalAmount.sub(_amount); 
            pool.totalAmount = pool.totalAmount.sub(_amount);
            _setIsWithdrawedToTrue(msg.sender, _lockedId);
            if (user.totalAmount == 0) {
                isStakedAddress[_user] = false;
                pool.totalStakedAddress = pool.totalStakedAddress.sub(1);
            }
        }
        for (uint256 rid = 0; rid < rewardTokenInfo.length; ++rid) {
            user.rewardDebt[rid] = user.totalAmount.mul(pool.accRewardPerShare[rid]).div(rewardTokenInfo[rid].magicNumber);
        }
        emit Withdraw(msg.sender, _amount, _lockedId, penlaty);
    }
    
    function _safeTokenTransfer(IERC20 _token, address _to, uint256 _amount) internal {
        uint256 tokenBal = _token.balanceOf(address(this));
        if (_amount > tokenBal) {
            _token.safeTransfer(_to, tokenBal);
        } else {
            _token.safeTransfer(_to, _amount);
        }
    }
    
    function _setIsWithdrawedToTrue(address _user, uint256 _lockedId) internal {
        UserInfo storage user = userInfo[_user];
        user.lockedInfo[_lockedId].isWithdrawed = true;
    }

    function addSetter(address _newSetter) external onlyOwner returns (bool) {
        require(_newSetter != address(0), "KISSBoardroom: NewSetter is the zero address");
        return EnumerableSet.add(_setter, _newSetter);
    }

    function delSetter(address _delSetter) external onlyOwner returns (bool) {
        require(_delSetter != address(0), "KISSBoardroom: DelSetter is the zero address");
        return EnumerableSet.remove(_setter, _delSetter);
    }
    
    function setRewardPeriod(uint256 _period) external onlyOwner {
        require(_period <= MAX_REWARD_PERIOD, "KISSBoardroom: max reward period");
        rewardPeriod = _period;
    }
    
    function setLockedTime(uint256 _min, uint256 _mid, uint256 _max) external onlyOwner {
        require(_min <= _mid && _mid <= _max && _max <= MAX_LOCK_TIME , "KISSBoardroom: invalid lockTime");
        minLockTime = _min;
        midLockTime = _mid;
        lockedTime = _max;
    }
    
    function setPenaltyPencentage(uint256 _min, uint256 _mid, uint256 _max) external onlyOwner {
        require(_min <= _mid && _mid <= _max && _max <= 100, "KISSBoardroom: invalid penalty percentage");
        minPenalty = _min;
        midPenalty = _mid;
        maxPenalty = _max;
    }
    
    function setPenaltyOn(bool _min, bool _mid, bool _max) external onlyOwner {
        minPenaltyOn = _min;
        midPenaltyOn = _mid;
        maxPenaltyOn = _max;
    }
    
    function emergencyWithdrawRewards(uint256 _rid) external onlyOwner {
        _safeTokenTransfer(rewardTokenInfo[_rid].rewardToken, msg.sender, rewardTokenInfo[_rid].rewardToken.balanceOf(address(this)));
    }
    
    function setDecimalsOfRewardToken(uint256 _rid, uint256 _decimals) external onlyOwner {
        RewardTokenInfo storage rewardToken = rewardTokenInfo[_rid];
        rewardToken.decimals = _decimals;
    }
    
    function setSymbolOfRewardToken(uint256 _rid, string memory _symbol) external onlyOwner {
        RewardTokenInfo storage rewardToken = rewardTokenInfo[_rid];
        rewardToken.symbol = _symbol;
    }

    function addRewardToken(uint256 _startTime, address _rewardToken, uint256 _decimals, string memory _symbol) external onlySetter {
        require(_startTime > block.timestamp, "KISSBoardroom: invalid start time");
        require(_rewardToken != address(poolInfo.stakedToken), "KISSBoardroom: staked token is reward token");
        require(!isExistedRewardToken[_rewardToken], "KISSBoardroom: existed reward token");
        require(rewardTokenInfo.length < MAX_REWOARD_TOKEN, "KISSBoardroom: max reward token");
        massUpdatePools();
        rewardTokenInfo.push(RewardTokenInfo({
            rewardToken: IERC20(_rewardToken),
            decimals: _decimals,
            symbol: _symbol,
            magicNumber: 10 ** (30 - _decimals),
            startTime: _startTime,
            endTime: _startTime - block.timestamp,
            rewardPerSec: 0,
            tokenRemaining: 0,
            tokenRewarded: 0,
            rid: rewardTokenInfo.length
        }));
        ridOfReward[_rewardToken] = rewardTokenInfo.length - 1;
        setterOfRid[rewardTokenInfo.length - 1] = msg.sender;
        isExistedRewardToken[_rewardToken] = true;
        emit RewardTokenAdded(_rewardToken, _decimals, rewardTokenInfo.length - 1);
    }
    
    function depoistRewardToken(uint256 _amount, uint256 _rid) onlySetter external {
        require(setterOfRid[_rid] == msg.sender, "KISSBoardroom: incorrect setter of this reward token pool");
        require(_amount > 0, "KISSBoardroom: zero amount");
        massUpdatePools();
        RewardTokenInfo storage token = rewardTokenInfo[_rid];
        uint256 prevBal = token.rewardToken.balanceOf(address(this));
        uint256 amountUnit = 10 ** token.decimals;
        token.rewardToken.safeTransferFrom(address(msg.sender), address(this), _amount.mul(amountUnit));
        uint256 currBal = token.rewardToken.balanceOf(address(this));
        require(currBal.sub(prevBal) == _amount.mul(amountUnit), "KISSBoardroom: incorrect balance after depositing");
        token.tokenRemaining = token.tokenRemaining.add(_amount.mul(amountUnit));
        token.rewardPerSec = token.tokenRemaining.div(rewardPeriod);
        token.endTime = block.timestamp.add(rewardPeriod);
    }
}