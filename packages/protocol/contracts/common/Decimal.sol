// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library Decimal {
    // unit is used for decimals, e.g. 0.123456
    function unit() internal pure returns (uint256) {
        return 1e18;
    }
}
