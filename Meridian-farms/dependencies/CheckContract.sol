// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;


contract CheckContract {
    /**
     * Check that the account is an already deployed non-destroyed contract.
     * See: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Address.sol#L12
     */
    function checkContract(address _account) internal view {
        require(_account != address(0), "Address cannot be zero address");

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(_account) }
        require(size > 0, "Contract code size cannot be zero");
    }

    function isContract(address _account) internal view returns(bool) {
        require(_account != address(0), "Address cannot be zero address");

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(_account) }
        if(size > 0){
            return true;
        }
        return false;
    }
}
