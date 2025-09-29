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
import {TreasuryFundedFarmingInit, LockstakeFarmingInitParams} from "./TreasuryFundedFarmingInit.sol";

contract TreasuryFundedFarmingInitTest is DssTest {
    ChainlogLike chainlog;
    MockSpell spell;
    address pause;
    address pauseProxy;
    address lssky;
    address sky;
    address rewards;
    address dist;
    address vest;
    address lockstakeEngine;
    address distJob;
    LockstakeFarmingInitParams p;

    function setUp() public {
        vm.createSelectFork("mainnet");
        chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        pause = chainlog.getAddress("MCD_PAUSE");
        pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");
        lockstakeEngine = chainlog.getAddress("LOCKSTAKE_ENGINE");
        lssky = chainlog.getAddress("LOCKSTAKE_SKY");
        sky = chainlog.getAddress("SKY");
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

        p = LockstakeFarmingInitParams({
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
            vestTau: 365 days,
            lockstakeEngine: lockstakeEngine
        });
        spell = new MockSpell();
    }

    function testInitLockstakeFarmActions() public {
        // Sanity checks
        assertEq(DssVestWithGemLike(vest).gem(), sky, "before: gem mismatch");

        assertEq(StakingRewardsLike(rewards).stakingToken(), lssky, "before: staking token mismatch");
        assertEq(StakingRewardsLike(rewards).rewardsToken(), sky, "before: rewards token mismatch");
        assertEq(StakingRewardsLike(rewards).rewardRate(), 0, "before: reward rate mismatch");
        assertEq(StakingRewardsLike(rewards).owner(), pauseProxy, "before: rewards owner mismatch");
        assertEq(StakingRewardsLike(rewards).rewardsDistribution(), address(0), "before: rewards distribution mismatch");

        assertEq(VestedRewardsDistributionLike(dist).gem(), sky, "before: gem mismatch");
        assertEq(VestedRewardsDistributionLike(dist).dssVest(), vest, "before: vest mismatch");
        assertEq(VestedRewardsDistributionLike(dist).vestId(), 0, "before: vest id already set");
        assertEq(VestedRewardsDistributionLike(dist).stakingRewards(), rewards, "before: staking rewards mismatch");

        assertFalse(VestedRewardsDistributionJobLike(distJob).has(dist), "before: job should not have dist");

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(rewards)),
            uint8(LockstakeEngineLike.FarmStatus.UNSUPPORTED),
            "before: lockstake engine should not have rewards"
        );

        // Initial state
        uint256 pallowance = ERC20Like(sky).allowance(pauseProxy, vest);
        uint256 pcap = DssVestWithGemLike(vest).cap();
        uint256 pvestCount = DssVestWithGemLike(vest).ids();

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.cast, (p)));

        assertEq(StakingRewardsLike(rewards).rewardRate(), p.vestTot / p.vestTau, "after: should set reward rate");
        assertEq(
            StakingRewardsLike(rewards).rewardsDistribution(), address(dist), "after: should set rewards distribution"
        );

        assertEq(VestedRewardsDistributionLike(dist).vestId(), pvestCount + 1, "after: should set the correct vestId");
        // Should distribute only if vesting period has already started
        if (p.vestBgn < block.timestamp) {
            assertEq(
                VestedRewardsDistributionLike(dist).lastDistributedAt(),
                block.timestamp,
                "after: should set the correct vestId"
            );
        }

        assertTrue(VestedRewardsDistributionJobLike(distJob).has(dist), "after: job should have dist");

        assertEq(
            DssVestWithGemLike(vest).ids(), pvestCount + 1, "after: should have created exactly 1 new vesting stream"
        );
        assertEq(DssVestWithGemLike(vest).unpaid(pvestCount + 1), 0, "after: should have distributed any unpaid amount");
        // Note: if there was a distribution, the allowance would've been decreased by the paid amount
        uint256 expectedAllowance = pallowance + p.vestTot - DssVestWithGemLike(vest).rxd(pvestCount + 1);
        assertEq(
            ERC20Like(sky).allowance(pauseProxy, vest), expectedAllowance, "after: should set the correct allowance"
        );

        // Adds 10% buffer
        uint256 expectedRateWithBuffer = (11 * p.vestTot) / p.vestTau / 10;
        if (expectedRateWithBuffer > pcap) {
            assertEq(DssVestWithGemLike(vest).cap(), expectedRateWithBuffer, "after: should set the correct cap");
        }

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(rewards)),
            uint8(LockstakeEngineLike.FarmStatus.ACTIVE),
            "before: lockstake engine should not have rewards"
        );
    }
}

contract MockSpell {
    function cast(LockstakeFarmingInitParams memory p) public {
        TreasuryFundedFarmingInit.initLockstakeFarm(p);
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
