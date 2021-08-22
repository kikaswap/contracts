pragma solidity >=0.6.0;
import "../openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IKISS is IERC20 {
    function mint(address to, uint256 amount) external returns (bool);
    function getMintInfo(address minter) external view returns (uint256 maxMint, uint256 nowMint);
}