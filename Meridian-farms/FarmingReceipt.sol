// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IFarmMaster.sol";

contract FarmingReceipt is ERC20 {
    address public factory;
    address public farmMaster;

    constructor(string memory name, string memory symbol, address _farmMaster) ERC20(name, symbol) {
        factory = msg.sender;
        farmMaster = _farmMaster;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == factory, "Not authorized to mint");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == factory, "Not authorized to burn");
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        decreaseFarmMasterBalance(msg.sender, amount);
        bool success = super.transfer(to, amount);
        increaseFarmMasterBalance(to, amount);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        decreaseFarmMasterBalance(from, amount);
        bool success  = super.transferFrom(from, to, amount);
        increaseFarmMasterBalance(to, amount);
        return success;
    }

    function increaseFarmMasterBalance(address user, uint256 _amount) private {
        FarmMaster(farmMaster).increaseBalance(user, _amount);
    }

    function decreaseFarmMasterBalance(address user, uint256 _amount) private {
        FarmMaster(farmMaster).decreaseBalance(user, _amount);
    }
}

