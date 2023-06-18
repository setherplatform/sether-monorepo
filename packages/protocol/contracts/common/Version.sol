// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/**
 * @dev Version contract gives the versioning information of the implementation contract
 */
contract Version {
    /**
     * @dev Returns the address of the current owner.
     */
    function version() public pure returns (bytes3) {
        // version 0.1.1
        return "011";
    }
}
