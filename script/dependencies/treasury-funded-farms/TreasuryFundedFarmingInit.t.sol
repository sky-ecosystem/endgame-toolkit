// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.16;

import {DssTest} from "dss-test/DssTest.sol";
import {StakingRewardsDeploy, StakingRewardsDeployParams} from "../StakingRewardsDeploy.sol";
import {
    VestedRewardsDistributionDeploy,
    VestedRewardsDistributionDeployParams
} from "../VestedRewardsDistributionDeploy.sol";
import {
    TreasuryFundedFarmingInit,
    FarmingInitParams,
    FarmingUpdateVestParams,
    FarmingUpdateVestResult
} from "./TreasuryFundedFarmingInit.sol";

contract TreasuryFundedFarmingInitTest is DssTest {
    ChainlogLike chainlog;
    MockSpell spell;
    address pause;
    address pauseProxy;
    address lssky;
    address sky;
    address usds;
    address vest;
    address lockstakeEngine;
    address distJob;
    FarmingInitParams lfp;
    FarmingInitParams fp;

    function setUp() public {
        vm.createSelectFork("mainnet");
        chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        pause = chainlog.getAddress("MCD_PAUSE");
        pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");
        lockstakeEngine = chainlog.getAddress("LOCKSTAKE_ENGINE");
        lssky = chainlog.getAddress("LOCKSTAKE_SKY");
        sky = chainlog.getAddress("SKY");
        usds = chainlog.getAddress("USDS");
        vest = chainlog.getAddress("MCD_VEST_SKY_TREASURY");
        distJob = chainlog.getAddress("CRON_REWARDS_DIST_JOB");

        lfp = FarmingInitParams({
            stakingToken: lssky,
            rewardsToken: sky,
            rewards: address(0),
            rewardsKey: "REWARDS_LSSKY_SKY",
            dist: address(0),
            distKey: "REWARDS_DIST_LSSKY_SKY",
            distJob: distJob,
            distJobInterval: 7 days - 1 hours,
            vest: vest,
            vestTot: 2_400_000 * 10 ** 18,
            vestBgn: block.timestamp - 7 days,
            vestTau: 365 days
        });
        lfp.rewards = StakingRewardsDeploy.deploy(
            StakingRewardsDeployParams({
                owner: pauseProxy, stakingToken: lfp.stakingToken, rewardsToken: lfp.rewardsToken
            })
        );
        lfp.dist = VestedRewardsDistributionDeploy.deploy(
            VestedRewardsDistributionDeployParams({
                deployer: address(this), owner: pauseProxy, vest: lfp.vest, rewards: lfp.rewards
            })
        );

        fp = FarmingInitParams({
            stakingToken: usds,
            rewardsToken: sky,
            rewards: address(0),
            rewardsKey: "REWARDS_LSSKY_SKY",
            dist: address(0),
            distKey: "REWARDS_DIST_LSSKY_SKY",
            distJob: distJob,
            distJobInterval: 7 days - 1 hours,
            vest: vest,
            vestTot: 2_400_000 * 10 ** 18,
            vestBgn: block.timestamp - 7 days,
            vestTau: 365 days
        });
        fp.rewards = StakingRewardsDeploy.deploy(
            StakingRewardsDeployParams({
                owner: pauseProxy, stakingToken: fp.stakingToken, rewardsToken: fp.rewardsToken
            })
        );
        fp.dist = VestedRewardsDistributionDeploy.deploy(
            VestedRewardsDistributionDeployParams({
                deployer: address(this), owner: pauseProxy, vest: fp.vest, rewards: fp.rewards
            })
        );

        spell = new MockSpell();
    }

    struct CheckInitFarmValuesBefore {
        uint256 allowance;
        uint256 cap;
        uint256 vestCount;
    }

    function testFarm_init() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        _checkFarm_init_afterSpell(fp, b);
    }

    function testFarm_init_whenVestingRateIsGreaterThanCurrentVestCap() public {
        CheckInitFarmValuesBefore memory b;

        // Force `vest.cap()` to return a lower value
        {
            vm.mockCall(address(fp.vest), abi.encodeWithSignature("cap()"), abi.encode(uint256(0)));

            b = _checkFarm_init_beforeSpell(fp);

            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        _checkFarm_init_afterSpell(fp, b);
    }

    function testFarm_integration_stakeGetRewardAndWithdraw_Fuzz(uint256 stakeAmt) public {
        // Bound `stakeAmt` to [1, 1_000_000_000_000]
        stakeAmt = bound(stakeAmt, 1 * 10 ** 18, 1_000_000_000_000 * 10 ** 18);

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Set `stakingToken` balance of the testing contract.
        address usr = address(this);
        deal(address(fp.stakingToken), usr, stakeAmt);

        // Approve `stakingToken` to the farming contract.
        ERC20Like(fp.stakingToken).approve(fp.rewards, stakeAmt);

        // Stake `stakingToken`
        uint256 pstakedBalance = StakingRewardsLike(fp.rewards).balanceOf(usr);
        StakingRewardsLike(fp.rewards).stake(stakeAmt);
        uint256 stakedBalance = StakingRewardsLike(fp.rewards).balanceOf(usr);
        assertEq(stakedBalance, pstakedBalance + stakeAmt, "_checkFarm_integration/staked-balance mismatch");

        // Accumulate rewards.
        vm.warp(block.timestamp + 1 days);

        // Check earned rewards.
        uint256 earnedAmt = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedAmt, 0, "_checkFarm_integration/earned-amt mismatch");

        // Claim earned rewards.
        uint256 prewardsTokenBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).getReward();
        uint256 rewardsTokenBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        assertEq(
            rewardsTokenBalance,
            prewardsTokenBalance + earnedAmt,
            "_checkFarm_integration/rewards-token-balance-mismatch"
        );

        // Withdraw staked tokens.
        uint256 pstakingTokenBalance = ERC20Like(fp.stakingToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).withdraw(stakeAmt);
        uint256 stakingTokenBalance = ERC20Like(fp.stakingToken).balanceOf(usr);
        assertEq(
            stakingTokenBalance,
            pstakingTokenBalance + stakeAmt,
            "_checkFarm_integration/staking-token-balance-mismatch"
        );
    }

    function testRevert_farm_init_whenMismatchingParams() public {
        // vest.czar != pauseProxy
        {
            vm.mockCall(address(fp.vest), abi.encodeWithSignature("czar()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // vest.gem != fp.rewardsToken
        {
            vm.mockCall(address(fp.vest), abi.encodeWithSignature("gem()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // rewards.stakingToken() != fp.stakingToken
        {
            vm.mockCall(address(fp.rewards), abi.encodeWithSignature("stakingToken()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // rewards.rewardsToken() != fp.rewardsToken
        {
            vm.mockCall(address(fp.rewards), abi.encodeWithSignature("rewardsToken()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // rewards.rewardRate != 0
        {
            vm.mockCall(address(fp.rewards), abi.encodeWithSignature("rewardRate()"), abi.encode(uint256(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // rewards.rewardsDistribution != address(0)
        {
            vm.mockCall(
                address(fp.rewards), abi.encodeWithSignature("rewardsDistribution()"), abi.encode(address(0x1337))
            );

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // rewards.owner() != MCD_PAUSE_PROXY
        {
            vm.mockCall(address(fp.rewards), abi.encodeWithSignature("owner()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // dist.gem != fp.rewardsToken
        {
            vm.mockCall(address(fp.dist), abi.encodeWithSignature("gem()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // dist.dssVest != fp.vest
        {
            vm.mockCall(address(fp.dist), abi.encodeWithSignature("dssVest()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // dist.vestId != 0
        {
            vm.mockCall(address(fp.dist), abi.encodeWithSignature("vestId()"), abi.encode(uint256(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }
    }

    function testLockstakeFarm_init() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(lfp);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.UNSUPPORTED),
            "before: lockstake engine should not have rewards"
        );

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initLockstakeFarm, (lfp, lockstakeEngine)));

        _checkFarm_init_afterSpell(lfp, b);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.ACTIVE),
            "after: lockstake engine should have rewards"
        );
    }

    function testLockstakeFarm_integration_openSelectFarmLockGetRewardAndFree_Fuzz(uint256 lockAmt) public {
        // Bound lockAmt to [1, 1_000_000_000_000]
        lockAmt = bound(lockAmt, 1 * 10 ** 18, 1_000_000_000_000 * 10 ** 18);

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initLockstakeFarm, (lfp, lockstakeEngine)));

        // Open a new urn
        address owner = address(this);

        uint256 ownerUrnsCount = LockstakeEngineLike(lockstakeEngine).ownerUrnsCount(owner);
        assertEq(ownerUrnsCount, 0, "_checkLockstakeFarm_integration/owner-urns-count-mismatch");

        uint256 urnIndex = ownerUrnsCount;
        address urn = LockstakeEngineLike(lockstakeEngine).open(urnIndex);

        // Select a farm
        LockstakeEngineLike(lockstakeEngine).selectFarm(owner, urnIndex, lfp.rewards, 0);
        assertEq(
            LockstakeEngineLike(lockstakeEngine).urnFarms(urn),
            lfp.rewards,
            "_checkLockstakeFarm_integration/urn-farm mismatch"
        );

        // Lock tokens
        address lockToken = LockstakeEngineLike(lockstakeEngine).sky();
        deal(address(lockToken), owner, lockAmt);

        ERC20Like(lockToken).approve(lockstakeEngine, type(uint256).max);
        LockstakeEngineLike(lockstakeEngine).lock(owner, urnIndex, lockAmt, 0);

        // Check staking token balance for the urn
        uint256 stakedAmt = StakingRewardsLike(lfp.rewards).balanceOf(urn);
        assertEq(stakedAmt, lockAmt, "_checkLockstakeFarm_integration/staking-token-balance-mismatch");

        // Accumulate rewards
        vm.warp(block.timestamp + 1 days);

        // Check earned rewards
        uint256 earnedAmt = StakingRewardsLike(lfp.rewards).earned(urn);
        assertGt(earnedAmt, 0, "_checkFarm_integration/earned-amt mismatch");

        // Get rewards
        uint256 prewardsTokenBalance = ERC20Like(lfp.rewardsToken).balanceOf(owner);
        LockstakeEngineLike(lockstakeEngine).getReward(owner, urnIndex, lfp.rewards, owner);
        uint256 rewardsTokenBalance = ERC20Like(lfp.rewardsToken).balanceOf(owner);
        assertEq(
            rewardsTokenBalance,
            prewardsTokenBalance + earnedAmt,
            "_checkLockstakeFarm_integration/rewards-token-balance mismatch"
        );

        // Free urn
        uint256 plockTokenBalance = ERC20Like(lockToken).balanceOf(owner);
        LockstakeEngineLike(lockstakeEngine).free(owner, urnIndex, owner, lockAmt);
        uint256 lockTokenBalance = ERC20Like(lockToken).balanceOf(owner);
        assertEq(
            lockTokenBalance, plockTokenBalance + lockAmt, "_checkLockstakeFarm_integration/lock-token-balance mismatch"
        );
    }

    function testRevert_lockstakeFarm_init_whenStakingTokenIsNotLssky() public {
        lfp.stakingToken = usds;

        // Simulate spell casting
        vm.prank(pause);
        vm.expectRevert("ds-pause-delegatecall-error");
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initLockstakeFarm, (lfp, lockstakeEngine)));
    }

    function _checkFarm_init_beforeSpell(FarmingInitParams memory p)
        internal
        view
        returns (CheckInitFarmValuesBefore memory b)
    {
        // Sanity checks
        assertEq(DssVestTransferrableLike(p.vest).gem(), sky, "before: gem mismatch");

        assertEq(StakingRewardsLike(p.rewards).stakingToken(), p.stakingToken, "before: staking token mismatch");
        assertEq(StakingRewardsLike(p.rewards).rewardsToken(), p.rewardsToken, "before: rewards token mismatch");
        assertEq(StakingRewardsLike(p.rewards).rewardRate(), 0, "before: reward rate mismatch");
        assertEq(StakingRewardsLike(p.rewards).owner(), pauseProxy, "before: rewards owner mismatch");
        assertEq(
            StakingRewardsLike(p.rewards).rewardsDistribution(), address(0), "before: rewards distribution mismatch"
        );

        assertEq(VestedRewardsDistributionLike(p.dist).gem(), p.rewardsToken, "before: gem mismatch");
        assertEq(VestedRewardsDistributionLike(p.dist).dssVest(), p.vest, "before: vest mismatch");
        assertEq(VestedRewardsDistributionLike(p.dist).vestId(), 0, "before: vest id already set");
        assertEq(VestedRewardsDistributionLike(p.dist).stakingRewards(), p.rewards, "before: staking rewards mismatch");

        assertFalse(VestedRewardsDistributionJobLike(p.distJob).has(p.dist), "before: job should not have dist");

        // Initial state
        b.allowance = ERC20Like(p.rewardsToken).allowance(pauseProxy, p.vest);
        b.cap = DssVestTransferrableLike(p.vest).cap();
        b.vestCount = DssVestTransferrableLike(p.vest).ids();
    }

    function _checkFarm_init_afterSpell(FarmingInitParams memory p, CheckInitFarmValuesBefore memory b) internal view {
        assertEq(StakingRewardsLike(p.rewards).rewardRate(), p.vestTot / p.vestTau, "after: should set reward rate");
        assertEq(
            StakingRewardsLike(p.rewards).rewardsDistribution(),
            address(p.dist),
            "after: should set rewards distribution"
        );

        assertEq(
            VestedRewardsDistributionLike(p.dist).vestId(), b.vestCount + 1, "after: should set the correct vestId"
        );
        // Should distribute only if vesting period has already started
        if (p.vestBgn < block.timestamp) {
            assertEq(
                VestedRewardsDistributionLike(p.dist).lastDistributedAt(),
                block.timestamp,
                "after: should set the correct vestId"
            );
        }

        assertTrue(VestedRewardsDistributionJobLike(p.distJob).has(p.dist), "after: job should have dist");

        assertEq(
            DssVestTransferrableLike(p.vest).ids(),
            b.vestCount + 1,
            "after: should have created exactly 1 new vesting stream"
        );
        assertEq(
            DssVestTransferrableLike(p.vest).unpaid(b.vestCount + 1),
            0,
            "after: should have distributed any unpaid amount"
        );
        // Note: if there was a distribution, the allowance would've been decreased by the paid amount
        uint256 expectedAllowance = b.allowance + p.vestTot - DssVestTransferrableLike(p.vest).rxd(b.vestCount + 1);
        assertEq(
            ERC20Like(sky).allowance(pauseProxy, p.vest), expectedAllowance, "after: should set the correct allowance"
        );

        // Adds 10% buffer
        uint256 expectedRateWithBuffer = (11 * p.vestTot) / (10 * p.vestTau);
        if (expectedRateWithBuffer > b.cap) {
            assertEq(
                DssVestTransferrableLike(p.vest).cap(), expectedRateWithBuffer, "after: should set the correct cap"
            );
        }
    }

    struct CheckUpdateFarmVestValuesBefore {
        uint256 allowance;
        uint256 vestCount;
        uint256 prevVestId;
        uint256 prevVestTot;
        uint256 prevVestRxd;
        uint256 prevUnpaid;
        uint256 rewardRate;
    }

    function testFarm_updateVest() public {
        // First initialize the farm
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Create update params with new vesting schedule
        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist,
            vestTot: 3_600_000 * 10 ** 18, // Increased amount
            vestBgn: block.timestamp + 1 days, // Start tomorrow
            vestTau: 180 days // Shorter vesting period
        });

        CheckUpdateFarmVestValuesBefore memory b = _checkFarm_updateVest_beforeSpell(updateParams);

        // Simulate spell casting for update
        vm.prank(pause);
        bytes memory returnData =
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));
        FarmingUpdateVestResult memory result = abi.decode(returnData, (FarmingUpdateVestResult));

        _checkFarm_updateVest_afterSpell(updateParams, b, result);
    }

    function testFarm_updateVest_withPreviousUnpaidAmount() public {
        // First initialize the farm with past start time to generate unpaid amount
        fp.vestBgn = block.timestamp - 7 days; // Started a week ago
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Fast forward to accumulate some unpaid amount
        vm.warp(block.timestamp + 3 days);

        // Create update params
        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist,
            vestTot: 4_800_000 * 10 ** 18, // Even larger amount
            vestBgn: block.timestamp - 1 days, // Start yesterday to create immediate unpaid amount
            vestTau: 90 days // Much shorter vesting period
        });

        CheckUpdateFarmVestValuesBefore memory b = _checkFarm_updateVest_beforeSpell(updateParams);

        // Ensure there's unpaid amount in previous vest
        assertGt(b.prevUnpaid, 0, "Previous vest should have unpaid amount for test");

        // Simulate spell casting for update
        vm.prank(pause);
        bytes memory returnData =
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));
        FarmingUpdateVestResult memory result = abi.decode(returnData, (FarmingUpdateVestResult));

        _checkFarm_updateVest_afterSpell(updateParams, b, result);

        // Verify both previous and new distributions happened
        assertGt(result.prevDistributedAmount, 0, "Should have distributed previous unpaid amount");
        assertGt(result.distributedAmount, 0, "Should have distributed new unpaid amount");
    }

    function testFarm_updateVest_integration_stakingStillWorksAfterUpdate() public {
        uint256 stakeAmt = 1000 * 10 ** 18;

        // Initialize farm
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Set up staking
        address usr = address(this);
        deal(address(fp.stakingToken), usr, stakeAmt);
        ERC20Like(fp.stakingToken).approve(fp.rewards, stakeAmt);
        StakingRewardsLike(fp.rewards).stake(stakeAmt);

        // Accumulate some rewards
        vm.warp(block.timestamp + 2 days);
        uint256 earnedBefore = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedBefore, 0, "Should have earned rewards before update");

        // Update the vest
        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist,
            vestTot: 1_200_000 * 10 ** 18, // Different amount
            vestBgn: block.timestamp + 1 hours,
            vestTau: 60 days
        });

        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));

        // Verify staking still works after update
        vm.warp(block.timestamp + 1 days);
        uint256 earnedAfter = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedAfter, earnedBefore, "Should continue earning rewards after update");

        // Verify we can still claim rewards
        uint256 preBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).getReward();
        uint256 postBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        assertGt(postBalance, preBalance, "Should receive rewards after update");
    }

    function testFarm_updateVest_whenCapNeedsAdjustment() public {
        // Initialize farm
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Record original cap and mock low cap to force adjustment
        address vestAddr = VestedRewardsDistributionLike(fp.dist).dssVest();
        uint256 originalCap = DssVestTransferrableLike(vestAddr).cap();
        vm.mockCall(address(vestAddr), abi.encodeWithSignature("cap()"), abi.encode(uint256(1)));

        // Create update params with high rate requiring cap adjustment
        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist,
            vestTot: 100_000_000 * 10 ** 18, // Very high amount to force cap adjustment
            vestBgn: block.timestamp + 1 days,
            vestTau: 1 days // Very short period = very high rate
        });

        uint256 expectedRateWithBuffer = (110 * updateParams.vestTot) / (100 * updateParams.vestTau);

        // Simulate spell casting for update
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));

        vm.clearMockedCalls();

        // Verify the vest was created successfully
        uint256 newVestId = VestedRewardsDistributionLike(fp.dist).vestId();
        assertGt(newVestId, 0, "New vest should be created");

        // Verify the cap was adjusted to the expected rate with buffer
        uint256 newCap = DssVestTransferrableLike(vestAddr).cap();
        assertEq(newCap, expectedRateWithBuffer, "Cap should be adjusted to expected rate with buffer");
        assertGt(newCap, originalCap, "New cap should be greater than original cap");
    }

    function testRevert_updateVest_whenVestCzarMismatch() public {
        // Initialize farm first
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Mock vest.czar() to return wrong address
        address vestAddr = VestedRewardsDistributionLike(fp.dist).dssVest();
        vm.mockCall(address(vestAddr), abi.encodeWithSignature("czar()"), abi.encode(address(0x1337)));

        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist, vestTot: 1_200_000 * 10 ** 18, vestBgn: block.timestamp + 1 days, vestTau: 90 days
        });

        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));

        vm.clearMockedCalls();
    }

    function testFarm_updateVest_allowanceCalculation() public {
        // Initialize farm
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Fast forward to create some received amount
        vm.warp(block.timestamp + 30 days);

        address vestAddr = VestedRewardsDistributionLike(fp.dist).dssVest();
        address rewardsToken = VestedRewardsDistributionLike(fp.dist).gem();
        uint256 prevVestId = VestedRewardsDistributionLike(fp.dist).vestId();

        // Record state before update
        uint256 prevVestTot = DssVestTransferrableLike(vestAddr).tot(prevVestId);

        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist,
            vestTot: 3_000_000 * 10 ** 18, // Different amount to test allowance calculation
            vestBgn: block.timestamp + 1 days,
            vestTau: 200 days
        });

        // Force some distribution to happen before update
        VestedRewardsDistributionLike(fp.dist).distribute();
        uint256 prevVestRxdAfterDist = DssVestTransferrableLike(vestAddr).rxd(prevVestId);

        // Record allowance after the distribution to get accurate baseline
        uint256 currAllowanceAfterDist = ERC20Like(rewardsToken).allowance(pauseProxy, vestAddr);

        // Update vest
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));

        // Check that allowance was correctly calculated
        uint256 currAllowanceAfter = ERC20Like(rewardsToken).allowance(pauseProxy, vestAddr);
        uint256 expectedChange = updateParams.vestTot - (prevVestTot - prevVestRxdAfterDist);
        uint256 expectedAllowance = currAllowanceAfterDist + expectedChange;

        // Use 1% tolerance for allowance calculation verification
        assertApproxEqRel(
            currAllowanceAfter,
            expectedAllowance,
            1e16, // 1% tolerance (1e18 = 100%)
            "Allowance calculation should be approximately correct"
        );
    }

    function testFarm_updateVest_vestCreationParameters() public {
        // Initialize farm
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        uint256 customVestTot = 5_000_000 * 10 ** 18;
        uint256 customVestBgn = block.timestamp + 7 days;
        uint256 customVestTau = 45 days;

        FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
            dist: fp.dist, vestTot: customVestTot, vestBgn: customVestBgn, vestTau: customVestTau
        });

        address vestAddr = VestedRewardsDistributionLike(fp.dist).dssVest();
        uint256 vestCountBefore = DssVestTransferrableLike(vestAddr).ids();

        // Update vest
        vm.prank(pause);
        bytes memory returnData =
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));
        FarmingUpdateVestResult memory result = abi.decode(returnData, (FarmingUpdateVestResult));

        // Verify new vest has correct parameters
        uint256 newVestId = result.vestId;
        assertEq(newVestId, vestCountBefore + 1, "Should create exactly one new vest");
        assertEq(DssVestTransferrableLike(vestAddr).tot(newVestId), customVestTot, "New vest should have correct total");

        // Verify the vest is properly linked to distribution
        assertEq(VestedRewardsDistributionLike(fp.dist).vestId(), newVestId, "Distribution should point to new vest");
    }

    function testRevert_updateVest_whenInvalidParams() public {
        // Initialize farm first
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Test vestTot = 0
        {
            FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
                dist: fp.dist,
                vestTot: 0, // Invalid
                vestBgn: block.timestamp + 1 days,
                vestTau: 90 days
            });

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));
        }

        // Test vestTau = 0 (division by zero risk)
        {
            FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
                dist: fp.dist,
                vestTot: 1_200_000 * 10 ** 18,
                vestBgn: block.timestamp + 1 days,
                vestTau: 0 // Invalid - would cause division by zero
            });

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));
        }

        // Test dist with vestId = 0 (not initialized)
        {
            // Deploy a new distribution that hasn't been initialized
            address uninitDist = VestedRewardsDistributionDeploy.deploy(
                VestedRewardsDistributionDeployParams({
                    deployer: address(this), owner: pauseProxy, vest: fp.vest, rewards: fp.rewards
                })
            );

            FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
                dist: uninitDist, // This dist has vestId = 0
                vestTot: 1_200_000 * 10 ** 18,
                vestBgn: block.timestamp + 1 days,
                vestTau: 90 days
            });

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));
        }

        // Test vest gem mismatch
        {
            address vestAddr = VestedRewardsDistributionLike(fp.dist).dssVest();
            vm.mockCall(address(vestAddr), abi.encodeWithSignature("gem()"), abi.encode(address(0x1337)));

            FarmingUpdateVestParams memory updateParams = FarmingUpdateVestParams({
                dist: fp.dist, vestTot: 1_200_000 * 10 ** 18, vestBgn: block.timestamp + 1 days, vestTau: 90 days
            });

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.updateFarmVest, (updateParams)));

            vm.clearMockedCalls();
        }
    }

    function _checkFarm_updateVest_beforeSpell(FarmingUpdateVestParams memory p)
        internal
        view
        returns (CheckUpdateFarmVestValuesBefore memory b)
    {
        address vestAddr = VestedRewardsDistributionLike(p.dist).dssVest();
        address rewardsToken = VestedRewardsDistributionLike(p.dist).gem();

        b.allowance = ERC20Like(rewardsToken).allowance(pauseProxy, vestAddr);
        b.vestCount = DssVestTransferrableLike(vestAddr).ids();
        b.prevVestId = VestedRewardsDistributionLike(p.dist).vestId();
        b.prevVestTot = DssVestTransferrableLike(vestAddr).tot(b.prevVestId);
        b.prevVestRxd = DssVestTransferrableLike(vestAddr).rxd(b.prevVestId);
        b.prevUnpaid = DssVestTransferrableLike(vestAddr).unpaid(b.prevVestId);
        b.rewardRate = StakingRewardsLike(VestedRewardsDistributionLike(p.dist).stakingRewards()).rewardRate();

        // Verify previous vest exists
        assertGt(b.prevVestId, 0, "before: should have existing vest to update");
    }

    function _checkFarm_updateVest_afterSpell(
        FarmingUpdateVestParams memory p,
        CheckUpdateFarmVestValuesBefore memory b,
        FarmingUpdateVestResult memory result
    ) internal {
        address vestAddr = VestedRewardsDistributionLike(p.dist).dssVest();
        address rewardsToken = VestedRewardsDistributionLike(p.dist).gem();
        address stakingRewards = VestedRewardsDistributionLike(p.dist).stakingRewards();

        // Verify result values
        assertEq(result.prevVestId, b.prevVestId, "after: should return correct previous vestId");
        assertEq(result.prevDistributedAmount, b.prevUnpaid, "after: should return correct previous distributed amount");

        // Verify new vest was created
        assertEq(DssVestTransferrableLike(vestAddr).ids(), b.vestCount + 1, "after: should create exactly one new vest");
        assertEq(result.vestId, b.vestCount + 1, "after: should return correct new vestId");

        // Verify new vest is set in distribution
        assertEq(
            VestedRewardsDistributionLike(p.dist).vestId(), result.vestId, "after: should update vestId in distribution"
        );

        // Verify previous vest was yanked (unpaid should be 0)
        assertEq(DssVestTransferrableLike(vestAddr).unpaid(b.prevVestId), 0, "after: yanked vest should have 0 unpaid");

        // Verify allowance was adjusted correctly
        uint256 expectedAllowance = b.allowance + p.vestTot - (b.prevVestTot - b.prevVestRxd) - result.distributedAmount;
        assertEq(
            ERC20Like(rewardsToken).allowance(pauseProxy, vestAddr),
            expectedAllowance,
            "after: should adjust allowance correctly"
        );

        // Note: The reward rate in StakingRewards is updated during distribution, not immediately
        // We verify that the new vesting parameters are in place, which will affect future distributions
        uint256 currentRewardRate = StakingRewardsLike(stakingRewards).rewardRate();
        // The reward rate should be positive only if there was a distribution
        if (result.distributedAmount > 0) {
            assertGt(currentRewardRate, 0, "after: reward rate should be positive when distribution occurred");
        }

        // Verify distributions occurred if there was unpaid amount
        if (p.vestBgn < block.timestamp) {
            assertEq(
                VestedRewardsDistributionLike(p.dist).lastDistributedAt(),
                block.timestamp,
                "after: should have distributed if vesting already started"
            );
        }
    }
}

contract MockSpell {
    function initFarm(FarmingInitParams memory p) public {
        TreasuryFundedFarmingInit.initFarm(p);
    }

    function initLockstakeFarm(FarmingInitParams memory p, address lockstakeEngine) public {
        TreasuryFundedFarmingInit.initLockstakeFarm(p, address(lockstakeEngine));
    }

    function updateFarmVest(FarmingUpdateVestParams memory p) public returns (FarmingUpdateVestResult memory r) {
        return TreasuryFundedFarmingInit.updateFarmVest(p);
    }
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address addr);
}

interface ProxyLike {
    function exec(address usr, bytes memory fax) external returns (bytes memory);
}

interface DssVestTransferrableLike {
    function cap() external view returns (uint256);
    function gem() external view returns (address);
    function ids() external view returns (uint256);
    function rxd(uint256 vestId) external view returns (uint256);
    function tot(uint256 vestId) external view returns (uint256);
    function unpaid(uint256 vestId) external view returns (uint256);
}

interface StakingRewardsLike {
    function balanceOf(address who) external view returns (uint256);
    function earned(address who) external view returns (uint256);
    function getReward() external;
    function owner() external view returns (address);
    function rewardRate() external view returns (uint256);
    function rewardsDistribution() external view returns (address);
    function rewardsToken() external view returns (address);
    function stake(uint256 amount) external;
    function stakingToken() external view returns (address);
    function withdraw(uint256 amount) external;
}

interface VestedRewardsDistributionLike {
    function dssVest() external view returns (address);
    function distribute() external;
    function gem() external view returns (address);
    function lastDistributedAt() external view returns (uint256);
    function stakingRewards() external view returns (address);
    function vestId() external view returns (uint256);
}

interface VestedRewardsDistributionJobLike {
    function has(address dist) external view returns (bool);
}

interface ERC20Like {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external;
    function balanceOf(address who) external view returns (uint256);
}

interface LockstakeEngineLike {
    enum FarmStatus {
        UNSUPPORTED,
        ACTIVE,
        DELETED
    }

    function farms(address farm) external view returns (FarmStatus);
    function free(address owner, uint256 urnIndex, address to, uint256 wad) external;
    function getReward(address owner, uint256 index, address farm, address to) external returns (uint256 amt);
    function lock(address owner, uint256 urnIndex, uint256 wad, uint16 ref) external;
    function open(uint256 urnIndex) external returns (address urn);
    function ownerUrnsCount(address owner) external view returns (uint256);
    function selectFarm(address owner, uint256 urnIndex, address farm, uint16 ref) external;
    function sky() external view returns (address);
    function urnFarms(address urn) external view returns (address);
}
