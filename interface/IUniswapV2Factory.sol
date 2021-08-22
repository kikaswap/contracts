pragma solidity >=0.6.0;

interface IUniswapV2Factory {
    function getPair(address token0, address token1) external view returns(address);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}