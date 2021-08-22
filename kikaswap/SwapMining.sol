pragma solidity >=0.6.0 <0.8.0;
import "../openzeppelin/contracts/access/Ownable.sol";
import "../openzeppelin/contracts/utils/EnumerableSet.sol";
import "../openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../openzeppelin/contracts/math/SafeMath.sol";
import "../interface/IUniswapV2Factory.sol";
import "../interface/IUniswapV2Pair.sol";
import "../interface/IKISS.sol";
import "../lib/UniswapV2Library.sol";

contract SwapMining is Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _whitelist;
    uint256 public startTime;
    uint256 public constant REDUCE_PERIOD = 365 days / 4;
    uint256 public constant RESERVE_PRECENTAGE = 89;
    uint256 public totalAllocPoint = 0;
    address public router;
    IUniswapV2Factory public factory;
    IKISS public kiss;
    address public targetToken;
    mapping(address => uint256) public pairOfPid;

    constructor(IKISS _kiss, IUniswapV2Factory _factory, address _router, address _targetToken, uint256 _startTime) public {
        kiss = _kiss;
        factory = _factory;
        router = _router;
        targetToken = _targetToken;
        startTime = _startTime;
    }

    struct UserInfo {
        uint256 quantity;
        uint256 blockNumber;
    }

    struct PoolInfo {
        address pair;
        uint256 quantity;
        uint256 totalQuantity;
        uint256 allocPoint;
        uint256 allocKissAmount;
        uint256 lastRewardTime;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;


    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }


    function addPair(uint256 _allocPoint, address _pair, bool _withUpdate) public onlyOwner {
        require(_pair != address(0), "_pair is the zero address");
        if (_withUpdate) {
            massMintPools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        pair : _pair,
        quantity : 0,
        totalQuantity : 0,
        allocPoint : _allocPoint,
        allocKissAmount : 0,
        lastRewardTime : lastRewardTime
        }));
        pairOfPid[_pair] = poolLength() - 1;
    }

    function setPair(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massMintPools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function addWhitelist(address _addToken) public onlyOwner returns (bool) {
        require(_addToken != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.add(_whitelist, _addToken);
    }

    function delWhitelist(address _delToken) public onlyOwner returns (bool) {
        require(_delToken != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.remove(_whitelist, _delToken);
    }

    function getWhitelistLength() public view returns (uint256) {
        return EnumerableSet.length(_whitelist);
    }

    function isWhitelist(address _token) public view returns (bool) {
        return EnumerableSet.contains(_whitelist, _token);
    }

    function getWhitelist(uint256 _index) public view returns (address){
        require(_index <= getWhitelistLength() - 1, "SwapMining: index out of bounds");
        return EnumerableSet.at(_whitelist, _index);
    }

    function setRouter(address newRouter) public onlyOwner {
        require(newRouter != address(0), "SwapMining: new router is the zero address");
        router = newRouter;
    }

    function phase(uint256 _timestamp) public view returns (uint256) {
        if (_timestamp > startTime) {
            return (_timestamp.sub(startTime).sub(1)).div(REDUCE_PERIOD) + 1;
        }
        return 0;
    }

    function reward(uint256 _timestamp) public view returns (uint256) {
        (uint256 maxMint,) = kiss.getMintInfo(address(this));
        if (_timestamp <= startTime) {
            return 0;
        }
        uint256 _phase = phase(_timestamp);
        uint256 periodReward = maxMint * 11 / 100 / REDUCE_PERIOD;
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
            _lastRewardTime = startTime;
            n++;
        }
        while (n < m) {
            uint256 r = n.mul(REDUCE_PERIOD).add(startTime);
            poolsReward = poolsReward.add((r.sub(_lastRewardTime)).mul(reward(r)));
            _lastRewardTime = r;
            n++;
        }
        poolsReward = poolsReward.add((_currentTime.sub(_lastRewardTime)).mul(reward(_currentTime)));
        return poolsReward;
    }

    function massMintPools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            mint(pid);
        }
    }

    function mint(uint256 _pid) public returns (bool) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return false;
        }
        uint256 poolsReward = getPoolsReward(pool.lastRewardTime, block.timestamp);
        if (poolsReward <= 0) {
            return false;
        }
        uint256 kissReward = poolsReward.mul(pool.allocPoint).div(totalAllocPoint);
        (uint256 maxMint, uint256 nowMint) = kiss.getMintInfo(address(this));
        kissReward = maxMint.sub(nowMint) > kissReward ? kissReward : maxMint.sub(nowMint);
        kiss.mint(address(this), kissReward);
        pool.allocKissAmount = pool.allocKissAmount.add(kissReward);
        pool.lastRewardTime = block.timestamp;
        return true;
    }

    function swap(address account, address input, address output, uint256 amount) public onlyRouter returns (bool) {
        require(account != address(0), "SwapMining: taker swap account is the zero address");
        require(input != address(0), "SwapMining: taker swap input is the zero address");
        require(output != address(0), "SwapMining: taker swap output is the zero address");

        if (poolLength() <= 0) {
            return false;
        }
        if (!isWhitelist(input) || !isWhitelist(output)) {
            return false;
        }
        address pair = UniswapV2Library.pairFor(address(factory), input, output);
        PoolInfo storage pool = poolInfo[pairOfPid[pair]];
        if (pool.pair != pair || pool.allocPoint <= 0) {
            return false;
        }
        uint256 quantity = getQuantity(output, amount, targetToken);
        if (quantity <= 0) {
            return false;
        }
        mint(pairOfPid[pair]);
        pool.quantity = pool.quantity.add(quantity);
        pool.totalQuantity = pool.totalQuantity.add(quantity);
        UserInfo storage user = userInfo[pairOfPid[pair]][account];
        user.quantity = user.quantity.add(quantity);
        user.blockNumber = block.number;
        return true;
    }

    function takerWithdraw() public {
        uint256 userSub;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][msg.sender];
            if (user.quantity > 0) {
                mint(pid);
                uint256 userReward = pool.allocKissAmount.mul(user.quantity).div(pool.quantity);
                pool.quantity = pool.quantity.sub(user.quantity);
                pool.allocKissAmount = pool.allocKissAmount.sub(userReward);
                user.quantity = 0;
                user.blockNumber = block.number;
                userSub = userSub.add(userReward);
            }
        }
        if (userSub <= 0) {
            return;
        }
        kiss.transfer(msg.sender, userSub);
    }

    function getUserReward(uint256 _pid) public view returns (uint256, uint256){
        require(_pid <= poolInfo.length - 1, "SwapMining: Not find this pool");
        uint256 userSub;
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][msg.sender];
        if (user.quantity > 0) {
            uint256 poolsReward = getPoolsReward(pool.lastRewardTime, block.timestamp);
            uint256 kissReward = poolsReward.mul(pool.allocPoint).div(totalAllocPoint);
            userSub = userSub.add((pool.allocKissAmount.add(kissReward)).mul(user.quantity).div(pool.quantity));
        }
        return (userSub, user.quantity);
    }

    function getPoolInfo(uint256 _pid) public view returns (address, address, uint256, uint256, uint256, uint256){
        require(_pid <= poolInfo.length - 1, "SwapMining: Not find this pool");
        PoolInfo memory pool = poolInfo[_pid];
        address token0 = IUniswapV2Pair(pool.pair).token0();
        address token1 = IUniswapV2Pair(pool.pair).token1();
        uint256 kissAmount = pool.allocKissAmount;
        uint256 poolsReward = getPoolsReward(pool.lastRewardTime, block.timestamp);
        uint256 kissReward = poolsReward.mul(pool.allocPoint).div(totalAllocPoint);
        kissAmount = kissAmount.add(kissReward);
        return (token0, token1, kissAmount, pool.totalQuantity, pool.quantity, pool.allocPoint);
    }

    modifier onlyRouter() {
        require(msg.sender == router, "SwapMining: caller is not the router");
        _;
    }

    function getQuantity(address outputToken, uint256 outputAmount, address anchorToken) public view returns (uint256) {
        uint256 quantity = 0;
        if (outputToken == anchorToken) {
            quantity = outputAmount;
        } else if (IUniswapV2Factory(factory).getPair(outputToken, anchorToken) != address(0)) {
            address pair0 = IUniswapV2Factory(factory).getPair(outputToken, anchorToken);
            quantity = IUniswapV2Pair(pair0).consult(outputToken, outputAmount);
        } else {
            uint256 length = getWhitelistLength();
            for (uint256 index = 0; index < length; index++) {
                address intermediate = getWhitelist(index);
                address pair0 = IUniswapV2Factory(factory).getPair(outputToken, intermediate);
                address pair1 = IUniswapV2Factory(factory).getPair(intermediate, anchorToken);
                if (pair0 != address(0) && pair1 != address(0)) {
                    uint256 interQuantity = IUniswapV2Pair(pair0).consult(outputToken, outputAmount);
                    quantity = IUniswapV2Pair(pair1).consult(intermediate, interQuantity);
                    break;
                }
            }
        }
        return quantity;
    }

}
