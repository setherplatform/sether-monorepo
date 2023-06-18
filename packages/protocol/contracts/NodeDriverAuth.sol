// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./common/Ownable.sol";
import "./Staking.sol";
import "./NodeDriver.sol";

contract NodeDriverAuth is Initializable, Ownable {
    using SafeMath for uint256;

    Staking internal staking;
    NodeDriver internal driver;

    // Initialize NodeDriverAuth, NodeDriver and Staking in one call to allow fewer genesis transactions
    function initialize(address _staking, address _driver, address _owner) external initializer {
        Ownable._initialize(_owner);
        driver = NodeDriver(_driver);
        staking = Staking(_staking);
    }

    function updateBackend(address newDriverAuth) external onlyOwner {
        driver.setBackend(newDriverAuth);
    }

    function incBalance(address acc, uint256 diff) external onlyStaking {
        require(acc == address(staking), "recipient is not the Staking contract");
        driver.setBalance(acc, address(acc).balance.add(diff));
    }

    function upgradeCode(address acc, address from) external onlyOwner {
        require(isContract(acc) && isContract(from), "not a contract");
        driver.copyCode(acc, from);
    }

    function copyCode(address acc, address from) external onlyOwner {
        driver.copyCode(acc, from);
    }

    function incNonce(address acc, uint256 diff) external onlyOwner {
        driver.incNonce(acc, diff);
    }

    function updateNetworkRules(bytes calldata diff) external onlyOwner {
        driver.updateNetworkRules(diff);
    }

    function updateNetworkVersion(uint256 version) external onlyOwner {
        driver.updateNetworkVersion(version);
    }

    function advanceEpochs(uint256 num) external onlyOwner {
        driver.advanceEpochs(num);
    }

    function updateValidatorWeight(uint256 validatorID, uint256 value) external onlyStaking {
        driver.updateValidatorWeight(validatorID, value);
    }

    function updateValidatorPubkey(uint256 validatorID, bytes calldata pubkey) external onlyStaking {
        driver.updateValidatorPubkey(validatorID, pubkey);
    }

    function setGenesisValidator(address _auth, uint256 validatorID, bytes calldata pubkey, uint256 status, uint256 createdEpoch, uint256 createdTime, uint256 deactivatedEpoch, uint256 deactivatedTime) external onlyDriver {
        staking.setGenesisValidator(_auth, validatorID, pubkey, status, createdEpoch, createdTime, deactivatedEpoch, deactivatedTime);
    }

    function setGenesisDelegation(address delegator, uint256 toValidatorID, uint256 stake, uint256 lockedStake, uint256 lockupFromEpoch, uint256 lockupEndTime, uint256 lockupDuration, uint256 earlyUnlockPenalty, uint256 rewards) external onlyDriver {
        staking.setGenesisDelegation(delegator, toValidatorID, stake, lockedStake, lockupFromEpoch, lockupEndTime, lockupDuration, earlyUnlockPenalty, rewards);
    }

    function deactivateValidator(uint256 validatorID, uint256 status) external onlyDriver {
        staking.deactivateValidator(validatorID, status);
    }

    function sealEpochValidators(uint256[] calldata nextValidatorIDs) external onlyDriver {
        staking.sealEpochValidators(nextValidatorIDs);
    }

    function sealEpoch(uint256[] calldata offlineTimes, uint256[] calldata offlineBlocks, uint256[] calldata uptimes, uint256[] calldata originatedTxsFee) external onlyDriver {
        staking.sealEpoch(offlineTimes, offlineBlocks, uptimes, originatedTxsFee);
    }

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    modifier onlyStaking() {
        require(msg.sender == address(staking), "caller is not the Staking contract");
        _;
    }

    modifier onlyDriver() {
        require(msg.sender == address(driver), "caller is not the NodeDriver contract");
        _;
    }
}
