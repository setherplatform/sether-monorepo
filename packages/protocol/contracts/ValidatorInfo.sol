// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./common/Ownable.sol";
import "./Staking.sol";

contract ValidatorInfo is Initializable, Ownable {
    mapping (uint => string) public stakerInfos;
    address internal stakingContractAddress;

    function initialize(address _stakerContractAddress, address owner) external initializer {
        Ownable._initialize(owner);
        stakingContractAddress = _stakerContractAddress;
    }

    function updateStakerContractAddress(address _stakerContractAddress) external onlyOwner {
        stakingContractAddress = _stakerContractAddress;
    }

    function setInfo(string calldata configUrl) external {
        Staking staking = Staking(stakingContractAddress);
        uint256 validatorID = staking.getValidatorID(msg.sender);
        require(validatorID != 0, "Address does not belong to a validator!");
        stakerInfos[validatorID] = configUrl;
        emit InfoUpdated(validatorID);
    }

    function getInfo(uint256 validatorID) external view returns (string memory) {
        return stakerInfos[validatorID];
    }

    event InfoUpdated(uint256 validatorID);
}
