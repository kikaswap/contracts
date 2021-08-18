// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../openzeppelin/contracts/access/Ownable.sol";
// import "../openzeppelin/contracts/utils/EnumerableSet.sol";
import "../openzeppelin/contracts//math/SafeMath.sol";

abstract contract DelegateERC20 is ERC20 {
    mapping (address => address) internal _delegates;
    uint256 public holders;

    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;
    mapping (address => uint32) public numCheckpoints;
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    mapping (address => uint) public nonces;

    function _mint(address account, uint256 amount) internal override virtual {
        if(amount > 0 && balanceOf(account) == 0) {
            holders = holders.add(1);
        }
        super._mint(account, amount);
        _moveDelegates(address(0), _delegates[account], amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override virtual {
        if(amount > 0 && balanceOf(recipient) == 0) {
            holders = holders.add(1);
        }
        super._transfer(sender, recipient, amount);
        if(amount > 0 && balanceOf(sender) == 0) {
            holders = holders.sub(1);
        }
        _moveDelegates(_delegates[sender], _delegates[recipient], amount);
    }

    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    function delegateBySig(address delegatee, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) external {
        bytes32 domainSeparator = keccak256( abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), getChainId(), address(this)) );
        bytes32 structHash = keccak256( abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry) );
        bytes32 digest = keccak256( abi.encodePacked("\x19\x01", domainSeparator, structHash) );
        address signatory = ecrecover(digest, v, r, s);
        
        require(signatory != address(0), "DelegateERC20::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "DelegateERC20::delegateBySig: invalid nonce");
        require(now <= expiry, "DelegateERC20::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    function getPriorVotes(address account, uint blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "DelegateERC20::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator);
        
        _delegates[delegator] = delegatee;
        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
        emit DelegateChanged(delegator, currentDelegate, delegatee);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(address delegatee, uint32 nCheckpoints, uint256 oldVotes, uint256 newVotes) internal {
        uint32 blockNumber = safe32(block.number, "DelegateERC20::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }

        return chainId;
    }

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);
}

contract KISS is DelegateERC20, Ownable {
    using SafeMath for uint256;
    // using EnumerableSet for EnumerableSet.AddressSet;
    
    struct MintInfo {
        bool inMap;
        bool isMinter;
        uint256 maxMint;
        uint256 nowMint;
        uint256 minterID;
    }

    address[] public minters;
    mapping(address => MintInfo) public mintInfo;
    uint256 private constant maxSupply = 210000000e18;
    uint256 public constant MAX_MINTER = 100;
    constructor() public ERC20("Kika Swap Share", "KISS"){
    }

    function mint(address _to, uint256 _amount) external onlyMinter returns (bool) {
        MintInfo storage info = mintInfo[msg.sender];
        if (_amount.add(info.nowMint) > info.maxMint) {
            return false;
        }
        _mint(_to, _amount);
        info.nowMint = info.nowMint.add(_amount);
        return true;
    }
    
    function getMaxSupply() external pure returns(uint256) {
        return maxSupply;
    }

    function addOrUpdateMinter(address _minter, uint256 _maxMint) external onlyOwner returns (bool) {
        require(_minter != address(0), "KISS: minter is the zero address");
        MintInfo storage info = mintInfo[_minter];
        uint256 sumMint = 0;
        for (uint256 i = 0; i < minters.length; i++) {
            uint256 mintbyaddress = _minter == minters[i] ? _maxMint : mintInfo[minters[i]].maxMint;
            sumMint = sumMint.add(mintbyaddress);
        }
        require(sumMint <= maxSupply, "KISS: mint amount larger than maxSupply");
        if (info.inMap) {
            require(_maxMint >= info.nowMint, "KISS: mint amount less than nowMint");
            info.maxMint = _maxMint;
        } else {
            require(minters.length < MAX_MINTER, "KISS: too many minter");
            info.inMap = true;
            info.isMinter = true;
            info.maxMint = _maxMint;
            info.nowMint = 0;
            info.minterID = minters.length;
            minters.push(_minter);
        }
        return true;
    }

    function delMinter(address _delMinter) external onlyOwner returns (bool) {
        require(isMinter(_delMinter), "KISS: address is not minter");
        mintInfo[_delMinter].isMinter = false;
        return true;
    }

    function getMinterLength() public view returns (uint256) {
        return minters.length;
    }

    function isMinter(address account) public view returns (bool) {
        return mintInfo[account].isMinter;
    }

    function getMinter(uint256 _index) external view onlyOwner returns (address){
        require(_index <= getMinterLength() - 1, "KISS: index out of bounds");
        return minters[_index];
    }
    
    function getMintInfo(address minter) external view returns (uint256 maxMint, uint256 nowMint) {
        MintInfo memory info = mintInfo[minter];
        maxMint = info.maxMint;
        nowMint = info.nowMint;
    }

    modifier onlyMinter() {
        require(isMinter(msg.sender), "KISS: caller is not the minter");
        _;
    }
}