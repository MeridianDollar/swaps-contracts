// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../dependencies/BEP20.sol";

contract LPToken1 is BEP20 {
    constructor() BEP20("LPToken1", "LP1") public {
        _mint(msg.sender, 10000 * 10 ** uint256(decimals()));
    }
}