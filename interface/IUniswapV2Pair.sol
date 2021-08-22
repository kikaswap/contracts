pragma solidity >=0.6.0;

interface IUniswapV2Pair {
    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
    function getFeeRate() external view returns(uint256);
    function token0() external view returns(address);
    function token1() external view returns(address);
    function mint(address to) external returns (uint liquidity);
    function transferFrom(address from, address to, uint value) external returns (bool);
    function burn(address to) external returns (uint amount0, uint amount1);
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function consult(address tokenIn, uint amountIn) external view returns (uint amountOut);
}
