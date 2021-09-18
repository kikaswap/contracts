pragma solidity >=0.6.0;
import "../interface/IUniswapV2Factory.sol";
import "../interface/IUniswapV2Pair.sol";
import "../openzeppelin/contracts/access/Ownable.sol";
import "../openzeppelin/contracts/utils/EnumerableSet.sol";

contract Oracle is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    address public factory;
    address public targetToken;
    EnumerableSet.AddressSet private _whitelist;
    EnumerableSet.AddressSet private _valueList;
    
    constructor(address _factory, address _targetToken) public {
        factory = _factory;
        targetToken = _targetToken;
    }
    
    function setFactory(address _factory) onlyOwner external {
        factory = _factory;
    }
    
    function setTargetToken(address _targetToken) onlyOwner external {
        targetToken = _targetToken;
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
    
    function addValuelist(address _pair) public onlyOwner returns (bool) {
        require(_pair != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.add(_valueList, _pair);
    }

    function delValuelist(address _pair) public onlyOwner returns (bool) {
        require(_pair != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.remove(_valueList, _pair);
    }

    function getValuelistLength() public view returns (uint256) {
        return EnumerableSet.length(_valueList);
    }

    function isValuelist(address _pair) public view returns (bool) {
        return EnumerableSet.contains(_valueList, _pair);
    }

    function getValuelist(uint256 _index) public view returns (address){
        require(_index <= getValuelistLength() - 1, "SwapMining: index out of bounds");
        return EnumerableSet.at(_valueList, _index);
    }
    
    function getQuantity(address outputToken, uint256 outputAmount, address anchorToken) public view returns (uint256) {
        uint256 quantity = 0;
        if (outputToken == anchorToken) {
            quantity = outputAmount;
        } else if (isValuelist(IUniswapV2Factory(factory).getPair(outputToken, anchorToken))) {
            address pair0 = IUniswapV2Factory(factory).getPair(outputToken, anchorToken);
            quantity = IUniswapV2Pair(pair0).consult(outputToken, outputAmount);
        } else {
            uint256 length = getWhitelistLength();
            for (uint256 index = 0; index < length; index++) {
                address intermediate = getWhitelist(index);
                address pair0 = IUniswapV2Factory(factory).getPair(outputToken, intermediate);
                address pair1 = IUniswapV2Factory(factory).getPair(intermediate, anchorToken);
                if (isValuelist(pair0) && isValuelist(pair1)) {
                    uint256 interQuantity = IUniswapV2Pair(pair0).consult(outputToken, outputAmount);
                    quantity = IUniswapV2Pair(pair1).consult(intermediate, interQuantity);
                    break;
                }
            }
        }
        return quantity;
    }
    
    function getQuantity(address outputToken, uint256 outputAmount) public view returns (uint256) {
        return getQuantity(outputToken, outputAmount, targetToken);
    }
} 