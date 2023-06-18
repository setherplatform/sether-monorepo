// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./Staking.sol";
import "./ValidatorInfo.sol";
import "./NodeDriver.sol";
import "./NodeDriverAuth.sol";
import "./NetworkRegistry.sol";

contract NetworkInitializer is NetworkConstants {
    function initializeAll(
        uint256 sealedEpoch,
        uint256 totalSupply,
        address _owner
    ) external {
        NodeDriver(NODE_DRIVER).initialize(NODE_DRIVER_AUTH, EVM_WRITER);
        NodeDriverAuth(NODE_DRIVER_AUTH).initialize(STAKING, NODE_DRIVER, _owner);
        Staking(STAKING).initialize(sealedEpoch, totalSupply, NODE_DRIVER_AUTH, _owner);
        ValidatorInfo(VALIDATOR_INFO).initialize(STAKING, _owner);
        selfdestruct(payable(address(0)));
    }
}
