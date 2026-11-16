// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>

pragma solidity ^0.8.16;

import {DssTest, AuthLike} from "dss-test/DssTest.sol";
import {StakingRewardsDeploy, StakingRewardsDeployParams} from "../StakingRewardsDeploy.sol";
import {
    VestedRewardsDistributionDeploy,
    VestedRewardsDistributionDeployParams
} from "../VestedRewardsDistributionDeploy.sol";
import {TreasuryFundedFarmingInit, FarmingInitParams, FarmingInitResult} from "./TreasuryFundedFarmingInit.sol";

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
            vestTau: 365 days,
            beam: address(0),
            beamKey: "REWARDS_BEAM_LSSKY_SKY",
            mom: address(0),
            momKey: "REWARDS_BEAM_MOM_LSSKY_SKY",
            buds: new address[](2),
            maxVestTot: 4_800_000 * 10 ** 18,
            tau: 1 days
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
            rewardsKey: "REWARDS_USDS_SKY",
            dist: address(0),
            distKey: "REWARDS_DIST_USDS_SKY",
            distJob: distJob,
            distJobInterval: 7 days - 1 hours,
            vest: vest,
            vestTot: 2_400_000 * 10 ** 18,
            vestBgn: block.timestamp - 7 days,
            vestTau: 365 days,
            beam: address(0),
            beamKey: "REWARDS_BEAM_USDS_SKY",
            mom: address(0),
            momKey: "REWARDS_BEAM_MOM_USDS_SKY",
            buds: new address[](2),
            maxVestTot: 4_800_000 * 10 ** 18,
            tau: 1 days
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

        _deployBeam(lfp);
        _deployBeam(fp);

        spell = new MockSpell();
    }

    struct CheckInitFarmValuesBefore {
        uint256 allowance;
        uint256 cap;
        uint256 vestCount;
        uint256 treasuryBalance;
        uint256 farmBalance;
    }

    function _deployBeam(FarmingInitParams storage p) internal {
        p.beam = deployCode("RewardsBeam.sol:RewardsBeam", abi.encode(p.dist));
        p.mom = deployCode("RewardsBeamMom.sol:RewardsBeamMom", abi.encode(p.beam));
        RewardsBeamLike(p.beam).rely(pauseProxy);
        RewardsBeamLike(p.beam).deny(address(this));
        RewardsBeamMomLike(p.mom).setOwner(pauseProxy);
        p.buds[0] = address(0xB0B);
        p.buds[1] = address(0xB0B2);
    }

    function testFarm_init() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);

        vm.prank(pause);
        bytes memory data = ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        FarmingInitResult memory result = abi.decode(data, (FarmingInitResult));
        _checkFarm_init_afterSpell(fp, b, result);
    }

    function testLockstakeFarm_init() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(lfp);

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)),
            uint8(LockstakeEngineLike.FarmStatus.UNSUPPORTED)
        );

        vm.prank(pause);
        bytes memory data =
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initLockstakeFarm, (lfp, lockstakeEngine)));

        _checkFarm_init_afterSpell(lfp, b, abi.decode(data, (FarmingInitResult)));

        assertEq(
            uint8(LockstakeEngineLike(lockstakeEngine).farms(lfp.rewards)), uint8(LockstakeEngineLike.FarmStatus.ACTIVE)
        );
    }

    function testFarm_init_whenVestingRateIsAboveOrBelowCurrentVestCap_Fuzz(
        bool initialTotalAboveMaximum,
        bool raiseCap
    ) public {
        // Exercise both cases: the initial stream total or the beam maximum determines the required cap
        fp.maxVestTot = initialTotalAboveMaximum ? fp.vestTot / 2 : fp.vestTot * 2;

        // Force a cap increase from zero or preserve an existing cap of 100 SKY per second
        vm.prank(pauseProxy);
        VestConfigLike(vest).file("cap", raiseCap ? 0 : 100 ether);

        // The shared checks verify the final cap, including the 10% buffer when an increase is required
        testFarm_init();
    }

    function testFarm_init_withExistingUnlimitedAllowance() public {
        vm.prank(pauseProxy);
        ERC20Like(sky).approve(vest, type(uint256).max);

        testFarm_init();
    }

    function testFarm_init_whenVestingHasNotStarted() public {
        fp.vestBgn = block.timestamp + 1 days;

        testFarm_init();
    }

    function testFarm_init_withoutFacilitators() public {
        delete fp.buds;
        fp.maxVestTot = 0;
        testFarm_init();

        assertEq(RewardsBeamLike(fp.beam).buds(address(0xB0B)), 0);
    }

    function testFarm_init_preservesExistingFarmOnSharedVest() public {
        // Initialize the Lockstake farm and its vesting stream
        testLockstakeFarm_init();

        // Record the existing stream before initializing another farm on the same DssVest
        uint256 lockstakeVestId = VestedRewardsDistributionLike(lfp.dist).vestId();
        uint256 lockstakeVestEnd = DssVestTransferrableLike(vest).fin(lockstakeVestId);
        uint256 lockstakeVestPaid = DssVestTransferrableLike(vest).rxd(lockstakeVestId);

        // Initialize the USDS farm with a separate stream, without replacing the Lockstake stream
        testFarm_init();

        // The Lockstake distributor keeps its stream, whose end and paid amount remain unchanged
        assertEq(VestedRewardsDistributionLike(lfp.dist).vestId(), lockstakeVestId);
        assertEq(DssVestTransferrableLike(vest).fin(lockstakeVestId), lockstakeVestEnd);
        assertEq(DssVestTransferrableLike(vest).rxd(lockstakeVestId), lockstakeVestPaid);

        // Both farms share DssVest but use different vesting stream IDs
        assertNotEq(lockstakeVestId, VestedRewardsDistributionLike(fp.dist).vestId());

        // Preserve the Lockstake beam's permissions and the shared treasury allowance
        assertEq(AuthLike(vest).wards(lfp.beam), 1);
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);
    }

    function testFarm_replaceVest_withPreviousUnpaidAmount() public {
        // Prepare the farm for replacement
        fp.maxVestTot = 5_000_000 ether;
        fp.vestTau = 45 days;
        vm.prank(pauseProxy);
        VestConfigLike(vest).file("cap", 0);
        testFarm_init();

        // Fast forward to accumulate some unpaid amount
        vm.warp(block.timestamp + 3 days);

        // Record state before replacement
        uint256 prevId = VestedRewardsDistributionLike(fp.dist).vestId();
        uint256 prevPaid = DssVestTransferrableLike(vest).rxd(prevId);
        uint256 unpaid = DssVestTransferrableLike(vest).unpaid(prevId);
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        uint256 farmBalance = ERC20Like(sky).balanceOf(fp.rewards);
        uint256 cap = DssVestTransferrableLike(vest).cap();
        assertGt(unpaid, 0, "Old stream should have pending rewards");

        // Replace the stream at the configured maximum
        vm.prank(fp.buds[0]);
        RewardsBeamLike(fp.beam).set(fp.maxVestTot);

        // Check the replacement stream ID
        uint256 id = VestedRewardsDistributionLike(fp.dist).vestId();
        assertEq(id, prevId + 1, "Distributor should point to the replacement");
        assertEq(DssVestTransferrableLike(vest).ids(), id, "Should create exactly one new stream");

        // Check the old stream was paid and terminated
        assertEq(DssVestTransferrableLike(vest).fin(prevId), block.timestamp, "Old stream should end now");
        assertEq(DssVestTransferrableLike(vest).rxd(prevId), prevPaid + unpaid, "Old stream should pay pending rewards");
        assertEq(DssVestTransferrableLike(vest).tot(prevId), prevPaid + unpaid);
        assertEq(DssVestTransferrableLike(vest).unpaid(prevId), 0);

        // Check the new stream parameters
        assertEq(DssVestTransferrableLike(fp.vest).tot(id), fp.maxVestTot, "Vesting total mismatch");
        assertEq(DssVestTransferrableLike(fp.vest).bgn(id), block.timestamp, "Vesting start mismatch");
        assertEq(DssVestTransferrableLike(fp.vest).fin(id), block.timestamp + fp.vestTau, "Vesting duration mismatch");
        assertEq(VestConfigLike(fp.vest).usr(id), fp.dist, "Vesting recipient mismatch");
        assertEq(VestConfigLike(fp.vest).res(id), 1, "Vesting stream should be restricted");
        assertEq(VestConfigLike(fp.vest).clf(id), block.timestamp, "Vesting stream should have no cliff");
        assertEq(VestConfigLike(fp.vest).mgr(id), address(0), "Vesting stream should have no manager");

        // Only the old stream should have paid
        assertEq(DssVestTransferrableLike(vest).rxd(id), 0, "Replacement should not pay immediately");
        assertEq(DssVestTransferrableLike(vest).unpaid(id), 0);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), treasuryBalance - unpaid);
        assertEq(ERC20Like(sky).balanceOf(fp.rewards), farmBalance + unpaid);
        assertEq(ERC20Like(sky).balanceOf(fp.dist), 0);

        // Replacement preserves unlimited allowance
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);

        // Replacement preserves the cap
        assertEq(DssVestTransferrableLike(vest).cap(), cap, "Replacement should preserve the prepared cap");
    }

    function testRevert_farm_init_whenInvalidParams() public {
        // Restore each parameter after its checks so subsequent cases start from a valid configuration
        uint256 total = fp.vestTot;

        // Reject an initial stream with a zero total
        fp.vestTot = 0;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Reject an initial total that exceeds DssVest's uint128 storage limit
        fp.vestTot = uint256(type(uint128).max) + 1;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        fp.vestTot = total;

        // Reject a maximum beam stream total that exceeds DssVest's uint128 storage limit
        uint256 maximum = fp.maxVestTot;
        fp.maxVestTot = uint256(type(uint128).max) + 1;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        fp.maxVestTot = maximum;

        uint256 duration = fp.vestTau;

        // Reject a zero vesting duration
        fp.vestTau = 0;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Reject a vesting duration longer than DssVest's twenty-year limit
        fp.vestTau = 20 * 365 days + 1;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        fp.vestTau = duration;

        // Reject a beam cooldown that exceeds its uint64 storage limit
        uint256 cooldown = fp.tau;
        fp.tau = uint256(type(uint64).max) + 1;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        fp.tau = cooldown;

        // Reject a zero address at any position in the facilitator list
        for (uint256 i; i < fp.buds.length; i++) {
            address bud = fp.buds[i];
            fp.buds[i] = address(0);
            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
            fp.buds[i] = bud;
        }
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

        // rewards.nominatedOwner() != address(0)
        {
            vm.mockCall(address(fp.rewards), abi.encodeWithSignature("nominatedOwner()"), abi.encode(address(0x1337)));

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

        // dist.stakingRewards() != fp.rewards
        {
            vm.mockCall(address(fp.dist), abi.encodeWithSignature("stakingRewards()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // beam.toc != 0
        {
            vm.mockCall(address(fp.beam), abi.encodeWithSignature("toc()"), abi.encode(uint256(1)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // beam.dist != fp.dist
        {
            vm.mockCall(address(fp.beam), abi.encodeWithSignature("dist()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // beam.vest != fp.vest
        {
            vm.mockCall(address(fp.beam), abi.encodeWithSignature("vest()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // mom.beam != fp.beam
        {
            vm.mockCall(address(fp.mom), abi.encodeWithSignature("beam()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // mom.dist != fp.dist
        {
            vm.mockCall(address(fp.mom), abi.encodeWithSignature("dist()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // mom.vest != fp.vest
        {
            vm.mockCall(address(fp.mom), abi.encodeWithSignature("vest()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // mom.owner != MCD_PAUSE_PROXY
        {
            vm.mockCall(address(fp.mom), abi.encodeWithSignature("owner()"), abi.encode(address(0x1337)));

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }

        // Chief must be a contract
        {
            vm.mockCall(
                address(chainlog),
                abi.encodeWithSignature("getAddress(bytes32)", bytes32("MCD_ADM")),
                abi.encode(address(0x1337))
            );

            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

            vm.clearMockedCalls();
        }
    }

    function testRevert_farm_init_whenInvalidChainlogKeys() public {
        bytes32[4] memory keys = [fp.rewardsKey, fp.distKey, fp.beamKey, fp.momKey];

        // Reject an empty key in each of the four Chainlog entries
        for (uint256 i; i < keys.length; i++) {
            bytes32 key = keys[i];
            keys[i] = bytes32(0);
            _setChainlogKeys(keys);
            vm.expectRevert("ds-pause-delegatecall-error");
            vm.prank(pause);
            ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
            keys[i] = key;
        }

        // Reject every pair of duplicate keys so one entry cannot overwrite another
        for (uint256 first; first < 3; first++) {
            for (uint256 second = first + 1; second < keys.length; second++) {
                bytes32 key = keys[second];
                keys[second] = keys[first];
                _setChainlogKeys(keys);
                vm.expectRevert("ds-pause-delegatecall-error");
                vm.prank(pause);
                ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
                keys[second] = key;
            }
        }

        // Restore the original keys after all invalid configurations have been checked
        _setChainlogKeys(keys);
    }

    function testRevert_farm_init_whenApprovalFails() public {
        // Reject a token approval that explicitly returns false
        vm.mockCall(
            sky, abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max), abi.encode(false)
        );
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        vm.clearMockedCalls();

        // Start from zero allowance, then simulate approve returning true without updating the allowance
        vm.prank(pauseProxy);
        ERC20Like(sky).approve(vest, 0);
        vm.mockCall(sky, abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max), abi.encode(true));

        // Reject the misleading success response because DssVest still lacks unlimited allowance
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        vm.clearMockedCalls();
    }

    function testRevert_farm_init_whenJobFails() public {
        // Record the initial state and force distribution job configuration to fail
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        vm.mockCallRevert(
            distJob,
            abi.encodeWithSignature("set(address,uint256)", fp.dist, fp.distJobInterval),
            abi.encodeWithSignature("Error(string)", "Job/set-failed")
        );

        // The job failure must revert the entire spell, including earlier initialization steps
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        // Roll back stream creation, cap changes, distributor setup and reward notification
        assertEq(DssVestTransferrableLike(vest).ids(), b.vestCount);
        assertEq(DssVestTransferrableLike(vest).cap(), b.cap);
        assertEq(VestedRewardsDistributionLike(fp.dist).vestId(), 0);
        assertEq(VestedRewardsDistributionLike(fp.dist).lastDistributedAt(), 0);
        assertEq(StakingRewardsLike(fp.rewards).rewardsDistribution(), address(0));
        assertEq(StakingRewardsLike(fp.rewards).rewardRate(), 0);

        // Roll back treasury approval and token transfers, leaving the job unregistered
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), b.allowance);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), b.treasuryBalance);
        assertEq(ERC20Like(sky).balanceOf(fp.rewards), b.farmBalance);
        assertFalse(VestedRewardsDistributionJobLike(distJob).has(fp.dist));

        // Beam and mom permissions and configuration must remain unset after the failed spell
        assertEq(AuthLike(vest).wards(fp.beam), 0);
        assertEq(AuthLike(vest).wards(fp.mom), 0);
        assertEq(AuthLike(fp.dist).wards(fp.beam), 0);
        assertEq(RewardsBeamLike(fp.beam).wards(fp.mom), 0);
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), 0);
        assertEq(RewardsBeamLike(fp.beam).vestTau(), 0);
        assertEq(RewardsBeamLike(fp.beam).tau(), 0);
        assertEq(RewardsBeamMomLike(fp.mom).authority(), address(0));

        // No facilitator should receive access from a failed initialization
        for (uint256 i; i < fp.buds.length; i++) {
            assertEq(RewardsBeamLike(fp.beam).buds(fp.buds[i]), 0);
        }
    }

    function testRevert_lockstakeFarm_init_whenStakingTokenIsNotLssky() public {
        // Supply USDS instead of the Lockstake engine's lssky staking token
        lfp.stakingToken = usds;

        // The staking token check must fail; the Pause Proxy wraps the underlying revert
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
        assertEq(DssVestTransferrableLike(p.vest).gem(), p.rewardsToken, "before: vest gem mismatch");

        assertEq(StakingRewardsLike(p.rewards).stakingToken(), p.stakingToken, "before: staking token mismatch");
        assertEq(StakingRewardsLike(p.rewards).rewardsToken(), p.rewardsToken, "before: rewards token mismatch");
        assertEq(StakingRewardsLike(p.rewards).rewardRate(), 0, "before: rewards already initialized");
        assertEq(StakingRewardsLike(p.rewards).owner(), pauseProxy, "before: rewards owner mismatch");
        assertEq(
            StakingRewardsLike(p.rewards).rewardsDistribution(), address(0), "before: rewards distribution mismatch"
        );

        assertEq(VestedRewardsDistributionLike(p.dist).gem(), p.rewardsToken, "before: distributor gem mismatch");
        assertEq(VestedRewardsDistributionLike(p.dist).dssVest(), p.vest, "before: vest mismatch");
        assertEq(VestedRewardsDistributionLike(p.dist).vestId(), 0, "before: distributor already initialized");
        assertEq(VestedRewardsDistributionLike(p.dist).stakingRewards(), p.rewards, "before: staking rewards mismatch");

        assertFalse(VestedRewardsDistributionJobLike(p.distJob).has(p.dist), "before: job should not have dist");

        // Initial state
        b.allowance = ERC20Like(p.rewardsToken).allowance(pauseProxy, p.vest);
        b.cap = DssVestTransferrableLike(p.vest).cap();
        b.vestCount = DssVestTransferrableLike(p.vest).ids();
        b.treasuryBalance = ERC20Like(p.rewardsToken).balanceOf(pauseProxy);
        b.farmBalance = ERC20Like(p.rewardsToken).balanceOf(p.rewards);
    }

    function _checkFarm_init_afterSpell(
        FarmingInitParams memory p,
        CheckInitFarmValuesBefore memory b,
        FarmingInitResult memory result
    ) internal view {
        // Calculate the first payout from the newly created stream, which has no cliff or previous payments
        uint256 expectedPayout;
        if (block.timestamp > p.vestBgn) {
            uint256 elapsed = block.timestamp - p.vestBgn;
            expectedPayout = p.vestTot * (elapsed < p.vestTau ? elapsed : p.vestTau) / p.vestTau;
        }

        // Verify returned values
        assertEq(result.vestId, b.vestCount + 1, "after: returned vest id mismatch");
        assertEq(result.distributedAmount, expectedPayout, "after: returned distribution mismatch");

        // Verify new vest was created
        assertEq(DssVestTransferrableLike(p.vest).ids(), result.vestId);

        // Verify new vest is set in distribution
        assertEq(VestedRewardsDistributionLike(p.dist).vestId(), result.vestId);

        // Verify new vest has correct parameters
        assertEq(DssVestTransferrableLike(p.vest).tot(result.vestId), p.vestTot, "Vesting total mismatch");
        assertEq(DssVestTransferrableLike(p.vest).bgn(result.vestId), p.vestBgn, "Vesting start mismatch");
        assertEq(
            DssVestTransferrableLike(p.vest).fin(result.vestId), p.vestBgn + p.vestTau, "Vesting duration mismatch"
        );
        assertEq(VestConfigLike(p.vest).usr(result.vestId), p.dist, "Vesting recipient mismatch");
        assertEq(VestConfigLike(p.vest).res(result.vestId), 1, "Vesting stream should be restricted");
        assertEq(VestConfigLike(p.vest).clf(result.vestId), p.vestBgn, "Vesting stream should have no cliff");
        assertEq(VestConfigLike(p.vest).mgr(result.vestId), address(0), "Vesting stream should have no manager");

        // Verify all accrued rewards were distributed
        assertEq(DssVestTransferrableLike(p.vest).rxd(result.vestId), expectedPayout);
        assertEq(DssVestTransferrableLike(p.vest).unpaid(result.vestId), 0);

        // Should distribute only if vesting has accrued a nonzero amount
        assertEq(VestedRewardsDistributionLike(p.dist).lastDistributedAt(), expectedPayout > 0 ? block.timestamp : 0);

        // Verify the reward rate and rewards distribution
        assertEq(
            StakingRewardsLike(p.rewards).rewardRate(), expectedPayout / StakingRewardsLike(p.rewards).rewardsDuration()
        );
        assertEq(StakingRewardsLike(p.rewards).rewardsDistribution(), p.dist);

        // Verify the payout moved from the treasury to the farm
        assertEq(ERC20Like(p.rewardsToken).balanceOf(pauseProxy), b.treasuryBalance - expectedPayout);
        assertEq(ERC20Like(p.rewardsToken).balanceOf(p.rewards), b.farmBalance + expectedPayout);

        // Unlimited allowance is preserved after distribution for future stream replacements
        assertEq(ERC20Like(p.rewardsToken).allowance(pauseProxy, p.vest), type(uint256).max);

        // Adds 10% buffer to the larger of the initial and maximum beam stream rates
        uint256 maxTot = p.vestTot > p.maxVestTot ? p.vestTot : p.maxVestTot;
        uint256 rateWithBuffer = (110 * maxTot) / (100 * p.vestTau);
        assertEq(DssVestTransferrableLike(p.vest).cap(), rateWithBuffer > b.cap ? rateWithBuffer : b.cap);

        // Verify the distribution job was configured
        assertTrue(VestedRewardsDistributionJobLike(p.distJob).has(p.dist));

        // Verify Chainlog entries
        assertEq(chainlog.getAddress(p.rewardsKey), p.rewards);
        assertEq(chainlog.getAddress(p.distKey), p.dist);
        assertEq(chainlog.getAddress(p.beamKey), p.beam);
        assertEq(chainlog.getAddress(p.momKey), p.mom);

        // Verify beam, mom and treasury permissions, with deployer permissions removed
        assertEq(AuthLike(p.vest).wards(p.beam), 1);
        assertEq(AuthLike(p.vest).wards(p.mom), 1);
        assertEq(AuthLike(p.dist).wards(p.beam), 1);
        assertEq(AuthLike(p.dist).wards(pauseProxy), 1);
        assertEq(AuthLike(p.dist).wards(address(this)), 0);
        assertEq(RewardsBeamLike(p.beam).wards(p.mom), 1);
        assertEq(RewardsBeamLike(p.beam).wards(pauseProxy), 1);
        assertEq(RewardsBeamLike(p.beam).wards(address(this)), 0);
        assertEq(AuthLike(p.vest).wards(address(this)), 0);

        // Verify mom ownership and governance authority
        assertEq(RewardsBeamMomLike(p.mom).owner(), pauseProxy);
        assertEq(RewardsBeamMomLike(p.mom).authority(), chainlog.getAddress("MCD_ADM"));

        // Only vest receives a treasury token allowance
        assertEq(ERC20Like(p.rewardsToken).allowance(pauseProxy, p.beam), 0);
        assertEq(ERC20Like(p.rewardsToken).allowance(pauseProxy, p.mom), 0);

        // Verify beam limits and initial cooldown state
        assertEq(RewardsBeamLike(p.beam).maxVestTot(), p.maxVestTot);
        assertEq(RewardsBeamLike(p.beam).vestTau(), p.vestTau);
        assertEq(RewardsBeamLike(p.beam).tau(), p.tau);
        assertEq(RewardsBeamLike(p.beam).toc(), 0);

        // Verify facilitators can replace streams without receiving admin permissions
        for (uint256 i; i < p.buds.length; i++) {
            assertEq(RewardsBeamLike(p.beam).buds(p.buds[i]), 1);
            assertEq(AuthLike(p.vest).wards(p.buds[i]), 0);
            assertEq(AuthLike(p.dist).wards(p.buds[i]), 0);
            assertEq(RewardsBeamLike(p.beam).wards(p.buds[i]), 0);
        }
    }

    function _setChainlogKeys(bytes32[4] memory keys) internal {
        fp.rewardsKey = keys[0];
        fp.distKey = keys[1];
        fp.beamKey = keys[2];
        fp.momKey = keys[3];
    }
}

contract MockSpell {
    function initFarm(FarmingInitParams memory p) public returns (FarmingInitResult memory) {
        return TreasuryFundedFarmingInit.initFarm(p);
    }

    function initLockstakeFarm(FarmingInitParams memory p, address lockstakeEngine)
        public
        returns (FarmingInitResult memory)
    {
        return TreasuryFundedFarmingInit.initLockstakeFarm(p, lockstakeEngine);
    }
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address addr);
}

interface ProxyLike {
    function exec(address usr, bytes memory fax) external returns (bytes memory);
}

interface DssVestTransferrableLike {
    function gem() external view returns (address);
    function cap() external view returns (uint256);
    function ids() external view returns (uint256);
    function bgn(uint256 vestId) external view returns (uint256);
    function fin(uint256 vestId) external view returns (uint256);
    function rxd(uint256 vestId) external view returns (uint256);
    function tot(uint256 vestId) external view returns (uint256);
    function unpaid(uint256 vestId) external view returns (uint256);
}

interface StakingRewardsLike {
    function stakingToken() external view returns (address);
    function rewardsToken() external view returns (address);
    function owner() external view returns (address);
    function rewardRate() external view returns (uint256);
    function rewardsDistribution() external view returns (address);
    function rewardsDuration() external view returns (uint256);
}

interface VestedRewardsDistributionLike {
    function gem() external view returns (address);
    function dssVest() external view returns (address);
    function stakingRewards() external view returns (address);
    function lastDistributedAt() external view returns (uint256);
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
}

interface RewardsBeamLike {
    function set(uint256 vestTot) external;
    function rely(address usr) external;
    function deny(address usr) external;
    function wards(address usr) external view returns (uint256);
    function buds(address usr) external view returns (uint256);
    function maxVestTot() external view returns (uint256);
    function vestTau() external view returns (uint256);
    function tau() external view returns (uint64);
    function toc() external view returns (uint128);
}

interface RewardsBeamMomLike {
    function setOwner(address owner) external;
    function owner() external view returns (address);
    function authority() external view returns (address);
}

interface VestConfigLike {
    function file(bytes32 what, uint256 data) external;
    function clf(uint256 id) external view returns (uint256);
    function mgr(uint256 id) external view returns (address);
    function res(uint256 id) external view returns (uint256);
    function usr(uint256 id) external view returns (address);
}
