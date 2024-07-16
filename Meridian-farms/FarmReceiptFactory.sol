// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/IERC20.sol";
import "../omnidex-core/interfaces/IOmnidexPair.sol";
import "./FarmingReceipt.sol";

contract FarmReceiptFactory {
    
    mapping(address => address) public lpToReceiptToken; // maps farmed lp token address to receipt token address

    event ReceiptIssued(address indexed user, address indexed lpToken, uint256 amount);
    event ReceiptBurnt(address indexed user, address indexed lpToken, uint256 amount);
    event TokenCreated(address indexed tokenAddress);

    function issueReceipt(address user, address lpToken, uint256 amount) external onlyFarmingContract {
        require(amount > 0, "Amount must be greater than zero");
        address receiptToken = _getOrCreateReceiptToken(lpToken);
        FarmingReceipt(receiptToken).mint(user, amount);
        emit ReceiptIssued(user, lpToken, amount);
    }

    function burnReceipt(address user, address lpToken, uint256 amount) external onlyFarmingContract {
        require(amount > 0, "Amount must be greater than zero");
        address receiptToken = lpToReceiptToken[lpToken];
        require(receiptToken != address(0), "No receipt token found for this lp token");
        require(IERC20(receiptToken).balanceOf(user)>= amount,"Insufficient receipt tokens");
        FarmingReceipt(receiptToken).burn(user, amount);
        emit ReceiptBurnt(user, lpToken, amount);
    }

    function _getOrCreateReceiptToken(address lpToken) internal returns (address) {
        if (lpToReceiptToken[lpToken] == address(0)) {
            address token0 = IOmnidexPair(lpToken).token0();
            address token1 = IOmnidexPair(lpToken).token1();
            // name the receipt token based on the underlying tokens for the LP eg mETHUSDC
            string memory name = string(abi.encodePacked("ReceiptToken_", IERC20(token0).symbol(), "_", IERC20(token1).symbol()));
            string memory symbol = string(abi.encodePacked("m", IERC20(token0).symbol(), IERC20(token1).symbol()));

            address receiptToken = _createToken(name, symbol);
            lpToReceiptToken[lpToken] = receiptToken;
        }
        return lpToReceiptToken[lpToken];
    }

    function _createToken(string memory name, string memory symbol) internal returns (address) {
        FarmingReceipt newToken = new FarmingReceipt(name, symbol);
        emit TokenCreated(address(newToken));
        return address(newToken);
    }
}
