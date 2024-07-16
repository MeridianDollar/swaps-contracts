// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IFarmReceiptFactory {
    function lpToReceiptToken(address) external view returns (address);
    function issueReceipt(address user, address lpToken, uint256 amount) external;
    function burnReceipt(address user, address lpToken, uint256 amount) external;
}
