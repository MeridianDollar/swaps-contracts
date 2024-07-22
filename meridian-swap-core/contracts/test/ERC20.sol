pragma solidity =0.5.16;

import '../MeridianERC20.sol';

contract ERC20 is MeridianERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}
