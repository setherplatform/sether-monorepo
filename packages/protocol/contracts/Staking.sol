// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./common/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./StakingConstants.sol";
import "./common/Version.sol";
import "./NodeDriverAuth.sol";
import "./StakingState.sol";

contract Staking is StakingState {
    using SafeMath for uint256;

    function initialize(uint256 sealedEpoch, uint256 _totalSupply, address nodeDriver, address owner) external initializer {
        Ownable._initialize(owner);
        currentSealedEpoch = sealedEpoch;
        node = NodeDriverAuth(nodeDriver);
        totalSupply = _totalSupply;
        baseRewardPerSecond = 6.183414351851851852 * 1e18;
        offlinePenaltyThresholdBlocksNum = 1000;
        offlinePenaltyThresholdTime = 3 days;
        getEpochSnapshot[sealedEpoch].endTime = _now();
    }

    function setGenesisValidator(address auth, uint256 validatorID, bytes calldata pubkey, uint256 status, uint256 createdEpoch, uint256 createdTime, uint256 deactivatedEpoch, uint256 deactivatedTime) external onlyDriver {
        _rawCreateValidator(auth, validatorID, pubkey, status, createdEpoch, createdTime, deactivatedEpoch, deactivatedTime);
        if (validatorID > lastValidatorID) {
            lastValidatorID = validatorID;
        }
    }

    function setGenesisDelegation(address delegator, uint256 toValidatorID, uint256 stake, uint256 lockedStake, uint256 lockupFromEpoch, uint256 lockupEndTime, uint256 lockupDuration, uint256 earlyUnlockPenalty, uint256 rewards) external onlyDriver {
        _rawDelegate(delegator, toValidatorID, stake);
        _rewardsStash[delegator][toValidatorID].unlockedReward = rewards;
        _mintNativeToken(stake);
        if (lockedStake != 0) {
            require(lockedStake <= stake, "locked stake is greater than the whole stake");
            LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
            ld.lockedStake = lockedStake;
            ld.fromEpoch = lockupFromEpoch;
            ld.endTime = lockupEndTime;
            ld.duration = lockupDuration;
            getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward = earlyUnlockPenalty;
            emit LockedUpStake(delegator, toValidatorID, lockupDuration, lockedStake);
        }
    }

    /*
    Methods
    */

    function createValidator(bytes calldata pubkey) external payable {
        require(msg.value >= minSelfStake(), "insufficient self-stake");
        require(pubkey.length > 0, "empty pubkey");
        _createValidator(msg.sender, pubkey);
        _delegate(msg.sender, lastValidatorID, msg.value);
    }

    function _createValidator(address auth, bytes memory pubkey) internal {
        uint256 validatorID = ++lastValidatorID;
        _rawCreateValidator(auth, validatorID, pubkey, OK_STATUS, currentEpoch(), _now(), 0, 0);
    }

    function _rawCreateValidator(address auth, uint256 validatorID, bytes memory pubkey, uint256 status, uint256 createdEpoch, uint256 createdTime, uint256 deactivatedEpoch, uint256 deactivatedTime) internal {
        require(getValidatorID[auth] == 0, "validator already exists");
        getValidatorID[auth] = validatorID;
        getValidator[validatorID].status = status;
        getValidator[validatorID].createdEpoch = createdEpoch;
        getValidator[validatorID].createdTime = createdTime;
        getValidator[validatorID].deactivatedTime = deactivatedTime;
        getValidator[validatorID].deactivatedEpoch = deactivatedEpoch;
        getValidator[validatorID].auth = auth;
        getValidatorPubkey[validatorID] = pubkey;

        emit CreatedValidator(validatorID, auth, createdEpoch, createdTime);
        if (deactivatedEpoch != 0) {
            emit DeactivatedValidator(validatorID, deactivatedEpoch, deactivatedTime);
        }
        if (status != 0) {
            emit ChangedValidatorStatus(validatorID, status);
        }
    }

    function _checkDelegatedStakeLimit(uint256 validatorID) internal view returns (bool) {
        return getValidator[validatorID].receivedStake <= getSelfStake(validatorID).mul(maxDelegatedRatio()).div(Decimal.unit());
    }

    function delegate(uint256 toValidatorID) external payable {
        _delegate(msg.sender, toValidatorID, msg.value);
    }

    function _delegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        require(_validatorExists(toValidatorID), "validator doesn't exist");
        require(getValidator[toValidatorID].status == OK_STATUS, "validator isn't active");
        _rawDelegate(delegator, toValidatorID, amount);
        require(_checkDelegatedStakeLimit(toValidatorID), "validator's delegations limit is exceeded");
    }

    function _rawDelegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        require(amount > 0, "zero amount");

        _stashRewards(delegator, toValidatorID);

        getStake[delegator][toValidatorID] = getStake[delegator][toValidatorID].add(amount);
        uint256 origStake = getValidator[toValidatorID].receivedStake;
        getValidator[toValidatorID].receivedStake = origStake.add(amount);
        totalStake = totalStake.add(amount);
        if (getValidator[toValidatorID].status == OK_STATUS) {
            totalActiveStake = totalActiveStake.add(amount);
        }

        _syncValidator(toValidatorID, origStake == 0);

        emit Delegated(delegator, toValidatorID, amount);
    }

    function _setValidatorDeactivated(uint256 validatorID, uint256 status) internal {
        if (getValidator[validatorID].status == OK_STATUS && status != OK_STATUS) {
            totalActiveStake = totalActiveStake.sub(getValidator[validatorID].receivedStake);
        }
        // status as a number is proportional to severity
        if (status > getValidator[validatorID].status) {
            getValidator[validatorID].status = status;
            if (getValidator[validatorID].deactivatedEpoch == 0) {
                getValidator[validatorID].deactivatedEpoch = currentEpoch();
                getValidator[validatorID].deactivatedTime = _now();
                emit DeactivatedValidator(validatorID, getValidator[validatorID].deactivatedEpoch, getValidator[validatorID].deactivatedTime);
            }
            emit ChangedValidatorStatus(validatorID, status);
        }
    }

    function _rawUndelegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        getStake[delegator][toValidatorID] -= amount;
        getValidator[toValidatorID].receivedStake = getValidator[toValidatorID].receivedStake.sub(amount);
        totalStake = totalStake.sub(amount);
        if (getValidator[toValidatorID].status == OK_STATUS) {
            totalActiveStake = totalActiveStake.sub(amount);
        }

        uint256 selfStakeAfterwards = getSelfStake(toValidatorID);
        if (selfStakeAfterwards != 0) {
            require(selfStakeAfterwards >= minSelfStake(), "insufficient self-stake");
            require(_checkDelegatedStakeLimit(toValidatorID), "validator's delegations limit is exceeded");
        } else {
            _setValidatorDeactivated(toValidatorID, WITHDRAWN_BIT);
        }
    }

    function undelegate(uint256 fromValidatorID, uint256 withdrawalRequestID, uint256 amount) public {
        address delegator = msg.sender;

        _stashRewards(delegator, fromValidatorID);

        require(amount > 0, "zero amount");
        require(amount <= getUnlockedStake(delegator, fromValidatorID), "not enough unlocked stake");

        require(getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID].amount == 0, "withdrawalRequestID already exists");

        _rawUndelegate(delegator, fromValidatorID, amount);

        getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID].amount = amount;
        getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID].epoch = currentEpoch();
        getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID].time = _now();

        _syncValidator(fromValidatorID, false);

        emit Undelegated(delegator, fromValidatorID, withdrawalRequestID, amount);
    }

    function getSlashingPenalty(uint256 amount, bool isCheater, uint256 refundRatio) internal pure returns (uint256 penalty) {
        if (!isCheater || refundRatio >= Decimal.unit()) {
            return 0;
        }
        // round penalty upwards (ceiling) to prevent dust amount attacks
        penalty = amount.mul(Decimal.unit() - refundRatio).div(Decimal.unit()).add(1);
        if (penalty > amount) {
            return amount;
        }
        return penalty;
    }

    function withdraw(uint256 fromValidatorID, uint256 withdrawalRequestID) public {
        address payable delegator = payable(msg.sender);
        WithdrawalRequest memory request = getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID];
        require(request.epoch != 0, "request doesn't exist");

        uint256 requestTime = request.time;
        uint256 requestEpoch = request.epoch;
        if (getValidator[fromValidatorID].deactivatedTime != 0 && getValidator[fromValidatorID].deactivatedTime < requestTime) {
            requestTime = getValidator[fromValidatorID].deactivatedTime;
            requestEpoch = getValidator[fromValidatorID].deactivatedEpoch;
        }

        require(_now() >= requestTime + withdrawalPeriodTime(), "not enough time passed");
        require(currentEpoch() >= requestEpoch + withdrawalPeriodEpochs(), "not enough epochs passed");

        uint256 amount = getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID].amount;
        bool isCheater = isSlashed(fromValidatorID);
        uint256 penalty = getSlashingPenalty(amount, isCheater, slashingRefundRatio[fromValidatorID]);
        delete getWithdrawalRequest[delegator][fromValidatorID][withdrawalRequestID];

        totalSlashedStake += penalty;
        require(amount > penalty, "stake is fully slashed");
        // It's important that we transfer after erasing (protection against Re-Entrancy)
        (bool sent, ) = delegator.call{value: amount.sub(penalty)}("");
        require(sent, "Failed to send SETH");

        emit Withdrawn(delegator, fromValidatorID, withdrawalRequestID, amount);
    }

    function deactivateValidator(uint256 validatorID, uint256 status) external onlyDriver {
        require(status != OK_STATUS, "wrong status");

        _setValidatorDeactivated(validatorID, status);
        _syncValidator(validatorID, false);
    }

    function _calcRawValidatorEpochBaseReward(uint256 epochDuration, uint256 _baseRewardPerSecond, uint256 baseRewardWeight, uint256 totalBaseRewardWeight) internal pure returns (uint256) {
        if (baseRewardWeight == 0) {
            return 0;
        }
        uint256 totalReward = epochDuration.mul(_baseRewardPerSecond);
        return totalReward.mul(baseRewardWeight).div(totalBaseRewardWeight);
    }

    function _calcRawValidatorEpochTxReward(uint256 epochFee, uint256 txRewardWeight, uint256 totalTxRewardWeight) internal pure returns (uint256) {
        if (txRewardWeight == 0) {
            return 0;
        }
        uint256 txReward = epochFee.mul(txRewardWeight).div(totalTxRewardWeight);
        // fee reward except burntFeeShare and treasuryFeeShare
        return txReward.mul(Decimal.unit() - burntFeeShare() - treasuryFeeShare()).div(Decimal.unit());
    }

    function _calcValidatorCommission(uint256 rawReward, uint256 commission) internal pure returns (uint256)  {
        return rawReward.mul(commission).div(Decimal.unit());
    }

    function _scaleLockupReward(uint256 fullReward, uint256 lockupDuration) internal pure returns (Rewards memory reward) {
        reward = Rewards(0, 0, 0);
        if (lockupDuration != 0) {
            uint256 maxLockupExtraRatio = Decimal.unit() - unlockedRewardRatio();
            uint256 lockupExtraRatio = maxLockupExtraRatio.mul(lockupDuration).div(maxLockupDuration());
            uint256 totalScaledReward = fullReward.mul(unlockedRewardRatio() + lockupExtraRatio).div(Decimal.unit());
            reward.lockupBaseReward = fullReward.mul(unlockedRewardRatio()).div(Decimal.unit());
            reward.lockupExtraReward = totalScaledReward - reward.lockupBaseReward;
        } else {
            reward.unlockedReward = fullReward.mul(unlockedRewardRatio()).div(Decimal.unit());
        }
        return reward;
    }

    function sumRewards(Rewards memory a, Rewards memory b) internal pure returns (Rewards memory) {
        return Rewards(a.lockupExtraReward.add(b.lockupExtraReward), a.lockupBaseReward.add(b.lockupBaseReward), a.unlockedReward.add(b.unlockedReward));
    }

    function sumRewards(Rewards memory a, Rewards memory b, Rewards memory c) internal pure returns (Rewards memory) {
        return sumRewards(sumRewards(a, b), c);
    }

    function _newRewards(address delegator, uint256 toValidatorID) internal view returns (Rewards memory) {
        uint256 stashedUntil = stashedRewardsUntilEpoch[delegator][toValidatorID];
        uint256 payableUntil = _highestPayableEpoch(toValidatorID);
        uint256 lockedUntil = _highestLockupEpoch(delegator, toValidatorID);
        if (lockedUntil > payableUntil) {
            lockedUntil = payableUntil;
        }
        if (lockedUntil < stashedUntil) {
            lockedUntil = stashedUntil;
        }

        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        uint256 wholeStake = getStake[delegator][toValidatorID];
        uint256 unlockedStake = wholeStake.sub(ld.lockedStake);
        uint256 fullReward;

        // count reward for locked stake during lockup epochs
        fullReward = _newRewardsOf(ld.lockedStake, toValidatorID, stashedUntil, lockedUntil);
        Rewards memory plReward = _scaleLockupReward(fullReward, ld.duration);
        // count reward for unlocked stake during lockup epochs
        fullReward = _newRewardsOf(unlockedStake, toValidatorID, stashedUntil, lockedUntil);
        Rewards memory puReward = _scaleLockupReward(fullReward, 0);
        // count lockup reward for unlocked stake during unlocked epochs
        fullReward = _newRewardsOf(wholeStake, toValidatorID, lockedUntil, payableUntil);
        Rewards memory wuReward = _scaleLockupReward(fullReward, 0);

        return sumRewards(plReward, puReward, wuReward);
    }

    function _newRewardsOf(uint256 stakeAmount, uint256 toValidatorID, uint256 fromEpoch, uint256 toEpoch) internal view returns (uint256) {
        if (fromEpoch >= toEpoch) {
            return 0;
        }
        uint256 stashedRate = getEpochSnapshot[fromEpoch].accumulatedRewardPerToken[toValidatorID];
        uint256 currentRate = getEpochSnapshot[toEpoch].accumulatedRewardPerToken[toValidatorID];
        return currentRate.sub(stashedRate).mul(stakeAmount).div(Decimal.unit());
    }

    function _pendingRewards(address delegator, uint256 toValidatorID) internal view returns (Rewards memory) {
        Rewards memory reward = _newRewards(delegator, toValidatorID);
        return sumRewards(_rewardsStash[delegator][toValidatorID], reward);
    }

    function pendingRewards(address delegator, uint256 toValidatorID) public view returns (uint256) {
        Rewards memory reward = _pendingRewards(delegator, toValidatorID);
        return reward.unlockedReward.add(reward.lockupBaseReward).add(reward.lockupExtraReward);
    }

    function stashRewards(address delegator, uint256 toValidatorID) external {
        require(_stashRewards(delegator, toValidatorID), "nothing to stash");
    }

    function _stashRewards(address delegator, uint256 toValidatorID) internal returns (bool updated) {
        Rewards memory nonStashedReward = _newRewards(delegator, toValidatorID);
        stashedRewardsUntilEpoch[delegator][toValidatorID] = _highestPayableEpoch(toValidatorID);
        _rewardsStash[delegator][toValidatorID] = sumRewards(_rewardsStash[delegator][toValidatorID], nonStashedReward);
        getStashedLockupRewards[delegator][toValidatorID] = sumRewards(getStashedLockupRewards[delegator][toValidatorID], nonStashedReward);
        if (!isLockedUp(delegator, toValidatorID)) {
            delete getLockupInfo[delegator][toValidatorID];
            delete getStashedLockupRewards[delegator][toValidatorID];
        }
        return nonStashedReward.lockupBaseReward != 0 || nonStashedReward.lockupExtraReward != 0 || nonStashedReward.unlockedReward != 0;
    }

    function _mintNativeToken(uint256 amount) internal {
        // balance will be increased after the transaction is processed
        node.incBalance(address(this), amount);
        totalSupply = totalSupply.add(amount);
    }

    function _claimRewards(address delegator, uint256 toValidatorID) internal returns (Rewards memory rewards) {
        _stashRewards(delegator, toValidatorID);
        rewards = _rewardsStash[delegator][toValidatorID];
        uint256 totalReward = rewards.unlockedReward.add(rewards.lockupBaseReward).add(rewards.lockupExtraReward);
        require(totalReward != 0, "zero rewards");
        delete _rewardsStash[delegator][toValidatorID];
        // It's important that we mint after erasing (protection against Re-Entrancy)
        _mintNativeToken(totalReward);
        return rewards;
    }

    function claimRewards(uint256 toValidatorID) public {
        address payable delegator = payable(msg.sender);
        Rewards memory rewards = _claimRewards(delegator, toValidatorID);
        // It's important that we transfer after erasing (protection against Re-Entrancy)
        (bool sent, ) = delegator.call{
            value: rewards.lockupExtraReward.add(rewards.lockupBaseReward).add(rewards.unlockedReward)
        }("");
        require(sent, "Failed to send SETH");

        emit ClaimedRewards(delegator, toValidatorID, rewards.lockupExtraReward, rewards.lockupBaseReward, rewards.unlockedReward);
    }

    function restakeRewards(uint256 toValidatorID) public {
        address delegator = msg.sender;
        Rewards memory rewards = _claimRewards(delegator, toValidatorID);

        uint256 lockupReward = rewards.lockupExtraReward.add(rewards.lockupBaseReward);
        _delegate(delegator, toValidatorID, lockupReward.add(rewards.unlockedReward));
        getLockupInfo[delegator][toValidatorID].lockedStake += lockupReward;
        emit RestakedRewards(delegator, toValidatorID, rewards.lockupExtraReward, rewards.lockupBaseReward, rewards.unlockedReward);
    }

    // _syncValidator updates the validator data on node
    function _syncValidator(uint256 validatorID, bool syncPubkey) public {
        require(_validatorExists(validatorID), "validator doesn't exist");
        // emit special log for node
        uint256 weight = getValidator[validatorID].receivedStake;
        if (getValidator[validatorID].status != OK_STATUS) {
            weight = 0;
        }
        node.updateValidatorWeight(validatorID, weight);
        if (syncPubkey && weight != 0) {
            node.updateValidatorPubkey(validatorID, getValidatorPubkey[validatorID]);
        }
    }

    function _sealEpoch_offline(EpochSnapshot storage snapshot, uint256[] memory validatorIDs, uint256[] memory offlineTime, uint256[] memory offlineBlocks) internal {
        // mark offline nodes
        for (uint256 i = 0; i < validatorIDs.length; i++) {
            if (offlineBlocks[i] > offlinePenaltyThresholdBlocksNum && offlineTime[i] >= offlinePenaltyThresholdTime) {
                _setValidatorDeactivated(validatorIDs[i], OFFLINE_BIT);
                _syncValidator(validatorIDs[i], false);
            }
            // log data
            snapshot.offlineTime[validatorIDs[i]] = offlineTime[i];
            snapshot.offlineBlocks[validatorIDs[i]] = offlineBlocks[i];
        }
    }

    function _sealEpoch_rewards(EpochSnapshot storage snapshot, uint256[] memory validatorIDs, uint256[] memory uptimes, uint256[] memory accumulatedOriginatedTxsFee) internal {
        SealEpochRewardsCtx memory ctx = SealEpochRewardsCtx(new uint[](validatorIDs.length), 0, new uint[](validatorIDs.length), 0, 0, 0);
        EpochSnapshot storage prevSnapshot = getEpochSnapshot[currentEpoch().sub(1)];

        ctx.epochDuration = 1;
        if (_now() > prevSnapshot.endTime) {
            ctx.epochDuration = _now() - prevSnapshot.endTime;
        }

        for (uint256 i = 0; i < validatorIDs.length; i++) {
            uint256 prevAccumulatedTxsFee = prevSnapshot.accumulatedOriginatedTxsFee[validatorIDs[i]];
            uint256 originatedTxsFee = 0;
            if (accumulatedOriginatedTxsFee[i] > prevAccumulatedTxsFee) {
                originatedTxsFee = accumulatedOriginatedTxsFee[i] - prevAccumulatedTxsFee;
            }
            // txRewardWeight = {originatedTxsFee} * {uptime}
            // originatedTxsFee is roughly proportional to {uptime} * {stake}, so the whole formula is roughly
            // {stake} * {uptime} ^ 2
            ctx.txRewardWeights[i] = originatedTxsFee * uptimes[i] / ctx.epochDuration;
            ctx.totalTxRewardWeight = ctx.totalTxRewardWeight.add(ctx.txRewardWeights[i]);
            ctx.epochFee = ctx.epochFee.add(originatedTxsFee);
        }

        for (uint256 i = 0; i < validatorIDs.length; i++) {
            // baseRewardWeight = {stake} * {uptime ^ 2}
            ctx.baseRewardWeights[i] = (((snapshot.receivedStake[validatorIDs[i]] * uptimes[i]) / ctx.epochDuration) * uptimes[i]) / ctx.epochDuration;
            ctx.totalBaseRewardWeight = ctx.totalBaseRewardWeight.add(ctx.baseRewardWeights[i]);
        }

        for (uint256 i = 0; i < validatorIDs.length; i++) {
            uint256 rawReward = _calcRawValidatorEpochBaseReward(ctx.epochDuration, baseRewardPerSecond, ctx.baseRewardWeights[i], ctx.totalBaseRewardWeight);
            rawReward = rawReward.add(_calcRawValidatorEpochTxReward(ctx.epochFee, ctx.txRewardWeights[i], ctx.totalTxRewardWeight));

            uint256 validatorID = validatorIDs[i];
            address validatorAddr = getValidator[validatorID].auth;
            // accounting validator's commission
            uint256 commissionRewardFull = _calcValidatorCommission(rawReward, validatorCommission());
            uint256 selfStake = getStake[validatorAddr][validatorID];
            if (selfStake != 0) {
                uint256 lCommissionRewardFull = (commissionRewardFull * getLockedStake(validatorAddr, validatorID)) / selfStake;
                uint256 uCommissionRewardFull = commissionRewardFull - lCommissionRewardFull;
                Rewards memory lCommissionReward = _scaleLockupReward(lCommissionRewardFull, getLockupInfo[validatorAddr][validatorID].duration);
                Rewards memory uCommissionReward = _scaleLockupReward(uCommissionRewardFull, 0);
                _rewardsStash[validatorAddr][validatorID] = sumRewards(_rewardsStash[validatorAddr][validatorID], lCommissionReward, uCommissionReward);
                getStashedLockupRewards[validatorAddr][validatorID] = sumRewards(getStashedLockupRewards[validatorAddr][validatorID], lCommissionReward, uCommissionReward);
            }
            // accounting reward per token for delegators
            uint256 delegatorsReward = rawReward - commissionRewardFull;
            // note: use latest stake for the sake of rewards distribution accuracy, not snapshot.receivedStake
            uint256 receivedStake = getValidator[validatorID].receivedStake;
            uint256 rewardPerToken = 0;
            if (receivedStake != 0) {
                rewardPerToken = (delegatorsReward * Decimal.unit()) / receivedStake;
            }
            snapshot.accumulatedRewardPerToken[validatorID] = prevSnapshot.accumulatedRewardPerToken[validatorID] + rewardPerToken;
            //
            snapshot.accumulatedOriginatedTxsFee[validatorID] = accumulatedOriginatedTxsFee[i];
            snapshot.accumulatedUptime[validatorID] = prevSnapshot.accumulatedUptime[validatorID] + uptimes[i];
        }

        snapshot.epochFee = ctx.epochFee;
        snapshot.totalBaseRewardWeight = ctx.totalBaseRewardWeight;
        snapshot.totalTxRewardWeight = ctx.totalTxRewardWeight;
    }

    function sealEpoch(uint256[] calldata offlineTime, uint256[] calldata offlineBlocks, uint256[] calldata uptimes, uint256[] calldata originatedTxsFee) external onlyDriver {
        EpochSnapshot storage snapshot = getEpochSnapshot[currentEpoch()];
        uint256[] memory validatorIDs = snapshot.validatorIDs;

        _sealEpoch_offline(snapshot, validatorIDs, offlineTime, offlineBlocks);
        _sealEpoch_rewards(snapshot, validatorIDs, uptimes, originatedTxsFee);

        currentSealedEpoch = currentEpoch();
        snapshot.endTime = _now();
        snapshot.baseRewardPerSecond = baseRewardPerSecond;
        snapshot.totalSupply = totalSupply;
    }

    function sealEpochValidators(uint256[] calldata nextValidatorIDs) external onlyDriver {
        // fill data for the next snapshot
        EpochSnapshot storage snapshot = getEpochSnapshot[currentEpoch()];
        for (uint256 i = 0; i < nextValidatorIDs.length; i++) {
            uint256 validatorID = nextValidatorIDs[i];
            uint256 receivedStake = getValidator[validatorID].receivedStake;
            snapshot.receivedStake[validatorID] = receivedStake;
            snapshot.totalStake = snapshot.totalStake.add(receivedStake);
        }
        snapshot.validatorIDs = nextValidatorIDs;
    }

    function _lockStake(address delegator, uint256 toValidatorID, uint256 lockupDuration, uint256 amount) internal {
        require(amount <= getUnlockedStake(delegator, toValidatorID), "not enough stake");
        require(getValidator[toValidatorID].status == OK_STATUS, "validator isn't active");

        require(lockupDuration >= minLockupDuration() && lockupDuration <= maxLockupDuration(), "incorrect duration");
        uint256 endTime = _now().add(lockupDuration);
        address validatorAddr = getValidator[toValidatorID].auth;
        if (delegator != validatorAddr) {
            require(getLockupInfo[validatorAddr][toValidatorID].endTime >= endTime, "validator lockup period will end earlier");
        }

        _stashRewards(delegator, toValidatorID);

        // check lockup duration after _stashRewards, which has erased previous lockup if it has unlocked already
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        require(lockupDuration >= ld.duration, "lockup duration cannot decrease");

        ld.lockedStake = ld.lockedStake.add(amount);
        ld.fromEpoch = currentEpoch();
        ld.endTime = endTime;
        ld.duration = lockupDuration;

        emit LockedUpStake(delegator, toValidatorID, lockupDuration, amount);
    }

    function lockStake(uint256 toValidatorID, uint256 lockupDuration, uint256 amount) public {
        address delegator = msg.sender;
        require(amount > 0, "zero amount");
        require(!isLockedUp(delegator, toValidatorID), "already locked up");
        _lockStake(delegator, toValidatorID, lockupDuration, amount);
    }

    function relockStake(uint256 toValidatorID, uint256 lockupDuration, uint256 amount) public {
        address delegator = msg.sender;
        _lockStake(delegator, toValidatorID, lockupDuration, amount);
    }

    function _popDelegationUnlockPenalty(address delegator, uint256 toValidatorID, uint256 unlockAmount, uint256 totalAmount) internal returns (uint256) {
        uint256 lockupExtraRewardShare = getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward.mul(unlockAmount).div(totalAmount);
        uint256 lockupBaseRewardShare = getStashedLockupRewards[delegator][toValidatorID].lockupBaseReward.mul(unlockAmount).div(totalAmount);
        uint256 penalty = lockupExtraRewardShare + lockupBaseRewardShare / 2;
        getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward = getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward.sub(lockupExtraRewardShare);
        getStashedLockupRewards[delegator][toValidatorID].lockupBaseReward = getStashedLockupRewards[delegator][toValidatorID].lockupBaseReward.sub(lockupBaseRewardShare);
        if (penalty >= unlockAmount) {
            penalty = unlockAmount;
        }
        return penalty;
    }

    function unlockStake(uint256 toValidatorID, uint256 amount) external returns (uint256) {
        address delegator = msg.sender;
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];

        require(amount > 0, "zero amount");
        require(isLockedUp(delegator, toValidatorID), "not locked up");
        require(amount <= ld.lockedStake, "not enough locked stake");

        _stashRewards(delegator, toValidatorID);

        uint256 penalty = _popDelegationUnlockPenalty(delegator, toValidatorID, amount, ld.lockedStake);

        ld.lockedStake -= amount;
        _rawUndelegate(delegator, toValidatorID, penalty);

        emit UnlockedStake(delegator, toValidatorID, amount, penalty);
        return penalty;
    }
}
