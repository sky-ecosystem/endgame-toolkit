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
    address rewards;
    address dist;
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

        rewards = StakingRewardsDeploy.deploy(
            StakingRewardsDeployParams({owner: pauseProxy, stakingToken: lssky, rewardsToken: sky})
        );
        dist = VestedRewardsDistributionDeploy.deploy(
            VestedRewardsDistributionDeployParams({
                deployer: address(this),
                owner: pauseProxy,
                vest: vest,
                rewards: rewards
            })
        );

        lfp = FarmingInitParams({
            admin: pauseProxy,
            stakingToken: lssky,
            rewardsToken: sky,
            rewards: rewards,
            rewardsKey: "REWARDS_LSSKY_SKY",
            dist: dist,
            distKey: "REWARDS_DIST_LSSKY_SKY",
            distJob: distJob,
            distJobInterval: 7 days - 1 hours,
            vest: vest,
            vestTot: 2_400_000,
            vestBgn: block.timestamp - 7 days,
            vestTau: 365 days
        });

        fp = FarmingInitParams({
            admin: pauseProxy,
            stakingToken: usds,
            rewardsToken: sky,
            rewards: rewards,
            rewardsKey: "REWARDS_LSSKY_SKY",
            dist: dist,
            distKey: "REWARDS_DIST_LSSKY_SKY",
            distJob: distJob,
            distJobInterval: 7 days - 1 hours,
            vest: vest,
            vestTot: 2_400_000,
            vestBgn: block.timestamp - 7 days,
            vestTau: 365 days
        });

        spell = new MockSpell();
    }

    struct CheckInitFarmBeforeValues {
        uint256 allowance;
        uint256 cap;
        uint256 vestCount;
    }

    function testInitFarm() public {
        CheckInitFarmBeforeValues memory v = _checkInitFarmActions_before(lfp);

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.cast, (lfp, lockstakeEngine)));

        _checkInitFarmActions_after(lfp, v);
    }

    function testInitLockstakeFarm() public {
        CheckInitFarmBeforeValues memory v = _checkInitFarmActions_before(lfp);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.UNSUPPORTED),
            "before: lockstake engine should not have rewards"
        );

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.cast, (lfp, lockstakeEngine)));

        _checkInitFarmActions_after(lfp, v);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.ACTIVE),
            "after: lockstake engine should have rewards"
        );
    }

    function _checkInitFarmActions_before(FarmingInitParams memory p)
        internal
        returns (CheckInitFarmBeforeValues memory v)
    {
        // Sanity checks
        assertEq(DssVestWithGemLike(vest).gem(), sky, "before: gem mismatch");

        assertEq(StakingRewardsLike(rewards).stakingToken(), p.stakingToken, "before: staking token mismatch");
        assertEq(StakingRewardsLike(rewards).rewardsToken(), p.rewardsToken, "before: rewards token mismatch");
        assertEq(StakingRewardsLike(rewards).rewardRate(), 0, "before: reward rate mismatch");
        assertEq(StakingRewardsLike(rewards).owner(), p.admin, "before: rewards owner mismatch");
        assertEq(StakingRewardsLike(rewards).rewardsDistribution(), address(0), "before: rewards distribution mismatch");

        assertEq(VestedRewardsDistributionLike(dist).gem(), p.rewardsToken, "before: gem mismatch");
        assertEq(VestedRewardsDistributionLike(dist).dssVest(), p.vest, "before: vest mismatch");
        assertEq(VestedRewardsDistributionLike(dist).vestId(), 0, "before: vest id already set");
        assertEq(VestedRewardsDistributionLike(dist).stakingRewards(), p.rewards, "before: staking rewards mismatch");

        assertFalse(VestedRewardsDistributionJobLike(p.distJob).has(dist), "before: job should not have dist");

        // Initial state
        v.allowance = ERC20Like(p.rewardsToken).allowance(p.admin, p.vest);
        v.cap = DssVestWithGemLike(p.vest).cap();
        v.vestCount = DssVestWithGemLike(p.vest).ids();
    }

    function _checkInitFarmActions_after(FarmingInitParams memory p, CheckInitFarmBeforeValues memory v) internal {
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
            DssVestWithGemLike(p.vest).ids(), v.vestCount + 1, "after: should have created exactly 1 new vesting stream"
        );
        assertEq(
            DssVestWithGemLike(p.vest).unpaid(v.vestCount + 1), 0, "after: should have distributed any unpaid amount"
        );
        // Note: if there was a distribution, the allowance would've been decreased by the paid amount
        uint256 expectedAllowance = v.allowance + p.vestTot - DssVestWithGemLike(vest).rxd(v.vestCount + 1);
        assertEq(
            ERC20Like(sky).allowance(p.admin, p.vest), expectedAllowance, "after: should set the correct allowance"
        );

        // Adds 10% buffer
        uint256 expectedRateWithBuffer = (11 * p.vestTot) / p.vestTau / 10;
        if (expectedRateWithBuffer > v.cap) {
            assertEq(DssVestWithGemLike(p.vest).cap(), expectedRateWithBuffer, "after: should set the correct cap");
        }
    }
}

contract MockSpell {
    function cast(FarmingInitParams memory lfp, address lockstakeEngine) public {
        TreasuryFundedFarmingInit.initLockstakeFarm(lfp, lockstakeEngine);
    }
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address addr);
}

interface ProxyLike {
    function exec(address usr, bytes memory fax) external returns (bytes memory);
}

interface DssVestWithGemLike {
    function cap() external view returns (uint256);

    function gem() external view returns (address);

    function ids() external view returns (uint256);

    function rxd(uint256 vestid) external view returns (uint256);

    function unpaid(uint256 vestid) external view returns (uint256);
}

interface StakingRewardsLike {
    function owner() external view returns (address);

    function rewardRate() external view returns (uint256);

    function rewardsDistribution() external view returns (address);

    function rewardsToken() external view returns (address);

    function stakingToken() external view returns (address);
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
}

interface LockstakeEngineLike {
    enum FarmStatus {
        UNSUPPORTED,
        ACTIVE,
        DELETED
    }

    function farms(address farm) external view returns (FarmStatus);
}
