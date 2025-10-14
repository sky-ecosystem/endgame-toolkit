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
import {TreasuryFundedFarmingInit, FarmingInitParams} from "./TreasuryFundedFarmingInit.sol";

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
                owner: pauseProxy,
                stakingToken: lfp.stakingToken,
                rewardsToken: lfp.rewardsToken
            })
        );
        lfp.dist = VestedRewardsDistributionDeploy.deploy(
            VestedRewardsDistributionDeployParams({
                deployer: address(this),
                owner: pauseProxy,
                vest: lfp.vest,
                rewards: lfp.rewards
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
            StakingRewardsDeployParams({owner: pauseProxy, stakingToken: fp.stakingToken, rewardsToken: fp.rewardsToken})
        );
        fp.dist = VestedRewardsDistributionDeploy.deploy(
            VestedRewardsDistributionDeployParams({
                deployer: address(this),
                owner: pauseProxy,
                vest: fp.vest,
                rewards: fp.rewards
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
        CheckInitFarmValuesBefore memory v = _checkFarm_init_beforeSpell(lfp);

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        _checkFarm_init_afterSpell(fp, v);
    }

    function testFarm_integration_stakeGetRewardAndwithdraw() internal {
        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Set `stakingToken` balance of the testing contract.
        uint256 stakeAmt = 100_000 * 10 ** 18;
        address usr = address(this);
        deal(address(fp.stakingToken), usr, stakeAmt);

        // Approve `stakingToken` to the farming contract.
        ERC20Like(fp.stakingToken).approve(fp.rewards, stakeAmt);

        // Stake `stakingToken`
        uint256 pstakedBalance = StakingRewardsLike(fp.rewards).balanceOf(usr);
        StakingRewardsLike(fp.rewards).stake(stakeAmt);
        uint256 stakedBalance = StakingRewardsLike(fp.rewards).balanceOf(usr);
        assertEq(stakedBalance, pstakedBalance + stakeAmt, "_checkFarm_integration/staked-balance mismatch");

        // Accumulate rewards
        vm.warp(block.timestamp + 1 days);

        // Check earned rewards
        uint256 earnedAmt = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedAmt, 0, "_checkFarm_integration/earned-amt mismatch");

        // Claim earned rewards
        uint256 prewardsTokenBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).getReward();
        uint256 rewardsTokenBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        assertEq(
            rewardsTokenBalance,
            prewardsTokenBalance + earnedAmt,
            "_checkFarm_integration/rewards-token-balance-mismatch"
        );

        // Withdraw staked tokens
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

        // reawards.stakingToken() != fp.stakingToken
        {
            vm.mockCall(address(fp.rewards), abi.encodeWithSignature("stakingToken()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // reawards.rewardsToken() != fp.rewardsToken
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

        // rewards.onwer() != MCD_PAUSE_PROXY
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
        CheckInitFarmValuesBefore memory v = _checkFarm_init_beforeSpell(lfp);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.UNSUPPORTED),
            "before: lockstake engine should not have rewards"
        );

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initLockstakeFarm, (lfp, lockstakeEngine)));

        _checkFarm_init_afterSpell(lfp, v);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.ACTIVE),
            "after: lockstake engine should have rewards"
        );
    }

    function testLockstakeFarm_integration_openSelectFarmLockGetRewardAndFree() public {
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
        uint256 lockAmt = 2_400_000 * 10 ** 18;
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
        returns (CheckInitFarmValuesBefore memory v)
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
        v.allowance = ERC20Like(p.rewardsToken).allowance(pauseProxy, p.vest);
        v.cap = DssVestTransferrableLike(p.vest).cap();
        v.vestCount = DssVestTransferrableLike(p.vest).ids();
    }

    function _checkFarm_init_afterSpell(FarmingInitParams memory p, CheckInitFarmValuesBefore memory v) internal view {
        assertEq(StakingRewardsLike(p.rewards).rewardRate(), p.vestTot / p.vestTau, "after: should set reward rate");
        assertEq(
            StakingRewardsLike(p.rewards).rewardsDistribution(),
            address(p.dist),
            "after: should set rewards distribution"
        );

        assertEq(
            VestedRewardsDistributionLike(p.dist).vestId(), v.vestCount + 1, "after: should set the correct vestId"
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
            v.vestCount + 1,
            "after: should have created exactly 1 new vesting stream"
        );
        assertEq(
            DssVestTransferrableLike(p.vest).unpaid(v.vestCount + 1),
            0,
            "after: should have distributed any unpaid amount"
        );
        // Note: if there was a distribution, the allowance would've been decreased by the paid amount
        uint256 expectedAllowance = v.allowance + p.vestTot - DssVestTransferrableLike(p.vest).rxd(v.vestCount + 1);
        assertEq(
            ERC20Like(sky).allowance(pauseProxy, p.vest), expectedAllowance, "after: should set the correct allowance"
        );

        // Adds 10% buffer
        uint256 expectedRateWithBuffer = (11 * p.vestTot) / p.vestTau / 10;
        if (expectedRateWithBuffer > v.cap) {
            assertEq(
                DssVestTransferrableLike(p.vest).cap(), expectedRateWithBuffer, "after: should set the correct cap"
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
    function rxd(uint256 vestid) external view returns (uint256);
    function unpaid(uint256 vestid) external view returns (uint256);
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
