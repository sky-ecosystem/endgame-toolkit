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
    uint256 initialVestCount;
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
        initialVestCount = DssVestTransferrableLike(vest).ids();
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

        assertEq(chainlog.getAddress(p.rewardsKey), p.rewards, "after: should set rewards chainlog entry");
        assertEq(chainlog.getAddress(p.distKey), p.dist, "after: should set dist chainlog entry");

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
        assertEq(
            ERC20Like(sky).allowance(pauseProxy, p.vest),
            type(uint256).max,
            "after: should retain unlimited allowance after initial distribution"
        );

        // Adds 10% buffer
        uint256 maxTot = p.vestTot > p.maxVestTot ? p.vestTot : p.maxVestTot;
        uint256 expectedRateWithBuffer = (11 * maxTot) / (10 * p.vestTau);
        if (expectedRateWithBuffer > b.cap) {
            assertEq(
                DssVestTransferrableLike(p.vest).cap(), expectedRateWithBuffer, "after: should set the correct cap"
            );
        }
    }

    function testFarm_init_whenBeamMaximumNeedsHigherCap() public {
        vm.prank(pauseProxy);
        VestConfigLike(vest).file("cap", 1);
        fp.maxVestTot = 100_000_000 ether;
        fp.vestBgn = block.timestamp;
        fp.vestTau = 1 days;

        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        uint256 expectedRateWithBuffer = (110 * fp.maxVestTot) / (100 * fp.vestTau);
        assertEq(DssVestTransferrableLike(vest).cap(), expectedRateWithBuffer);
        assertGt(expectedRateWithBuffer, 1);
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), fp.maxVestTot);
        assertEq(RewardsBeamLike(fp.beam).vestTau(), fp.vestTau);
    }

    function testFarm_beamConfiguration() public {
        vm.prank(pause);
        bytes memory data = ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        FarmingInitResult memory result = abi.decode(data, (FarmingInitResult));
        assertEq(result.vestId, VestedRewardsDistributionLike(fp.dist).vestId());
        assertEq(result.distributedAmount, DssVestTransferrableLike(vest).rxd(result.vestId));
        assertGt(result.distributedAmount, 0);
        assertEq(AuthLike(vest).wards(fp.beam), 1);
        assertEq(AuthLike(vest).wards(fp.mom), 1);
        assertEq(AuthLike(fp.dist).wards(fp.beam), 1);
        assertEq(RewardsBeamLike(fp.beam).wards(fp.mom), 1);
        assertEq(RewardsBeamLike(fp.beam).wards(pauseProxy), 1);
        assertEq(RewardsBeamLike(fp.beam).wards(address(this)), 0);
        assertEq(AuthLike(vest).wards(address(this)), 0);
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), fp.maxVestTot);
        assertEq(RewardsBeamLike(fp.beam).vestTau(), fp.vestTau);
        assertEq(RewardsBeamLike(fp.beam).tau(), fp.tau);
        assertEq(RewardsBeamLike(fp.beam).toc(), 0);
        for (uint256 i; i < fp.buds.length; i++) {
            assertEq(RewardsBeamLike(fp.beam).buds(fp.buds[i]), 1);
            assertEq(AuthLike(vest).wards(fp.buds[i]), 0);
            assertEq(AuthLike(fp.dist).wards(fp.buds[i]), 0);
            assertEq(RewardsBeamLike(fp.beam).wards(fp.buds[i]), 0);
        }
        assertEq(RewardsBeamMomLike(fp.mom).authority(), chainlog.getAddress("MCD_ADM"));
        assertEq(chainlog.getAddress(fp.beamKey), fp.beam);
        assertEq(chainlog.getAddress(fp.momKey), fp.mom);
    }

    function testFarm_init_withExistingUnlimitedAllowance() public {
        vm.prank(pauseProxy);
        ERC20Like(sky).approve(vest, type(uint256).max);
        // The previous helper overflowed when adding the initial total to this approval.
        testFarm_init();
    }

    function testFarm_init_upgradesFiniteAllowance() public {
        vm.prank(pauseProxy);
        ERC20Like(sky).approve(vest, 200_000_000 ether);
        testFarm_init();
    }

    function testFarm_init_unlimitedAllowance() public {
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        vm.prank(pause);
        bytes memory data = ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        FarmingInitResult memory result = abi.decode(data, (FarmingInitResult));
        assertGt(result.distributedAmount, 0);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), treasuryBalance - result.distributedAmount);
        // SKY does not decrease an unlimited approval on transferFrom.
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);
    }

    function testFarm_init_sharedVestAllowance() public {
        testLockstakeFarm_init();
        testFarm_init();
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);
        // Both farms retain independent beam permissions on the shared vest.
        assertEq(AuthLike(vest).wards(lfp.beam), 1);
        assertEq(AuthLike(vest).wards(fp.beam), 1);
        assertNotEq(VestedRewardsDistributionLike(lfp.dist).vestId(), VestedRewardsDistributionLike(fp.dist).vestId());
    }

    function testRevert_farm_init_insufficientTreasuryBalance() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        deal(sky, pauseProxy, 0);
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        _assertInitUnchanged(0, b);
    }

    function testRevert_farm_init_invalidBeamCooldown() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        fp.tau = uint256(type(uint64).max) + 1;
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        // Invalid cooldowns must be rejected before stream creation, funding and permissions.
        assertEq(DssVestTransferrableLike(vest).ids(), b.vestCount);
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), b.allowance);
        assertEq(AuthLike(vest).wards(fp.beam), 0);
        assertEq(RewardsBeamLike(fp.beam).wards(fp.mom), 0);
    }

    function testRevert_farm_init_failedApproval() public {
        fp.vestBgn = block.timestamp + 1 days;
        vm.mockCall(
            sky, abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max), abi.encode(false)
        );
        _assertInitReverts("initFarm/rewards-approve-failed");
    }

    function testRevert_farm_init_unchangedAllowance() public {
        fp.vestBgn = block.timestamp + 1 days;
        vm.prank(pauseProxy);
        ERC20Like(sky).approve(vest, 0);
        vm.mockCall(sky, abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max), abi.encode(true));
        _assertInitReverts("initFarm/rewards-allowance-mismatch");
    }

    function testRevert_farm_init_impossibleBeamMaximum() public {
        fp.maxVestTot = uint256(type(uint128).max) + 1;
        _assertInitReverts("initFarm/max-vest-tot-too-large");
    }

    function testRevert_farm_init_largestNumericInputs() public {
        uint256 initialTotal = fp.vestTot;
        fp.vestTot = type(uint256).max;
        _assertInitReverts("initFarm/vest-tot-too-large");
        fp.vestTot = initialTotal;
        uint256 maximumTotal = fp.maxVestTot;
        fp.maxVestTot = type(uint256).max;
        _assertInitReverts("initFarm/max-vest-tot-too-large");
        fp.maxVestTot = maximumTotal;
        fp.tau = type(uint256).max;
        _assertInitReverts("initFarm/invalid-tau");
    }

    function testRevert_farm_init_pendingOwner() public {
        vm.prank(pauseProxy);
        StakingRewardsLike(fp.rewards).nominateNewOwner(address(0xBAD));
        _assertInitReverts("initFarm/pending-owner");
    }

    function testRevert_farm_init_invalidDuration() public {
        fp.vestTau = 0;
        _assertInitReverts("initFarm/vest-tau-zero");
        fp.vestTau = 20 * 365 days + 1;
        _assertInitReverts("initFarm/vest-tau-too-long");
    }

    function testRevert_farm_init_invalidInitialTotal() public {
        fp.vestTot = 0;
        _assertInitReverts("initFarm/vest-tot-zero");
        fp.vestTot = uint256(type(uint128).max) + 1;
        _assertInitReverts("initFarm/vest-tot-too-large");
    }

    function testRevert_farm_init_invalidChief() public {
        vm.mockCall(
            address(chainlog),
            abi.encodeWithSignature("getAddress(bytes32)", bytes32("MCD_ADM")),
            abi.encode(address(0xBAD))
        );
        // Failure after funding and permission changes must undo the whole initialization.
        _assertInitReverts("initFarm/invalid-chief");
    }

    function testRevert_farm_init_zeroFacilitator() public {
        for (uint256 i; i < fp.buds.length; i++) {
            address bud = fp.buds[i];
            fp.buds[i] = address(0);
            _assertInitReverts("initFarm/zero-facilitator");
            fp.buds[i] = bud;
        }
    }

    function testRevert_farm_init_zeroChainlogKey() public {
        bytes32[4] memory keys = [fp.rewardsKey, fp.distKey, fp.beamKey, fp.momKey];
        for (uint256 i; i < keys.length; i++) {
            bytes32 key = keys[i];
            keys[i] = bytes32(0);
            _setChainlogKeys(keys);
            _assertInitReverts("initFarm/zero-chainlog-key");
            keys[i] = key;
        }
        _setChainlogKeys(keys);
    }

    function testRevert_farm_init_eachChainlogKeyCollision() public {
        bytes32[4] memory keys = [fp.rewardsKey, fp.distKey, fp.beamKey, fp.momKey];
        for (uint256 first; first < 3; first++) {
            for (uint256 second = first + 1; second < keys.length; second++) {
                bytes32 key = keys[second];
                keys[second] = keys[first];
                _setChainlogKeys(keys);
                _assertInitReverts("initFarm/duplicate-chainlog-key");
                keys[second] = key;
            }
        }
        _setChainlogKeys(keys);
    }

    function _setChainlogKeys(bytes32[4] memory keys) internal {
        fp.rewardsKey = keys[0];
        fp.distKey = keys[1];
        fp.beamKey = keys[2];
        fp.momKey = keys[3];
    }

    function testRevert_farm_init_duplicateChainlogKeys_Fuzz(uint256 first, uint256 second) public {
        first = bound(first, 0, 2);
        second = bound(second, first + 1, 3);
        bytes32[4] memory keys = [fp.rewardsKey, fp.distKey, fp.beamKey, fp.momKey];
        keys[second] = keys[first];
        _setChainlogKeys(keys);
        _assertInitReverts("initFarm/duplicate-chainlog-key");
    }

    function _assertInitReverts(string memory reason) internal {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        _assertInitFailure(reason);
        _assertInitUnchanged(treasuryBalance, b);
    }

    function _assertInitFailure(string memory reason) internal {
        vm.prank(pause);
        bytes memory data = ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.tryInitFarm, (fp)));
        (bool success, bytes memory result) = abi.decode(data, (bool, bytes));
        assertFalse(success, "Initialization should fail");
        assertEq(result, abi.encodeWithSignature("Error(string)", reason), "Unexpected initialization failure");
    }

    function _assertInitUnchanged(uint256 treasuryBalance, CheckInitFarmValuesBefore memory b) internal view {
        assertEq(DssVestTransferrableLike(vest).ids(), b.vestCount);
        assertEq(DssVestTransferrableLike(vest).cap(), b.cap);
        assertEq(VestedRewardsDistributionLike(fp.dist).vestId(), 0);
        assertEq(StakingRewardsLike(fp.rewards).rewardsDistribution(), address(0));
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), b.allowance);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), treasuryBalance);
        assertEq(ERC20Like(sky).balanceOf(fp.rewards), 0);
        assertEq(AuthLike(vest).wards(fp.beam), 0);
        assertEq(AuthLike(vest).wards(fp.mom), 0);
        assertEq(AuthLike(fp.dist).wards(fp.beam), 0);
        assertEq(RewardsBeamLike(fp.beam).wards(fp.mom), 0);
        for (uint256 i; i < fp.buds.length; i++) {
            assertEq(RewardsBeamLike(fp.beam).buds(fp.buds[i]), 0);
        }
    }

    function _initFarm() internal returns (FarmingInitResult memory result) {
        vm.prank(pause);
        bytes memory data = ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        result = abi.decode(data, (FarmingInitResult));
    }

    function _assertInitWithoutAccrual() internal {
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        FarmingInitResult memory result = _initFarm();
        assertEq(result.vestId, initialVestCount + 1);
        assertEq(result.distributedAmount, 0);
        assertEq(DssVestTransferrableLike(vest).tot(result.vestId), fp.vestTot);
        assertEq(DssVestTransferrableLike(vest).bgn(result.vestId), fp.vestBgn);
        assertEq(DssVestTransferrableLike(vest).fin(result.vestId), fp.vestBgn + fp.vestTau);
        assertEq(VestConfigLike(vest).res(result.vestId), 1);
        assertEq(VestConfigLike(vest).usr(result.vestId), fp.dist);
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), fp.maxVestTot);
        assertEq(RewardsBeamLike(fp.beam).vestTau(), fp.vestTau);
        assertEq(RewardsBeamLike(fp.beam).tau(), fp.tau);
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), treasuryBalance);
        assertGe(DssVestTransferrableLike(vest).cap(), fp.vestTot / fp.vestTau);
        assertGe(DssVestTransferrableLike(vest).cap(), fp.maxVestTot / fp.vestTau);
    }

    function testFarm_init_validParameters_Fuzz(
        uint128 initialTotal,
        uint128 maximumTotal,
        uint32 duration,
        uint64 cooldown,
        uint32 startDelay,
        uint256 allowance
    ) public {
        fp.vestTot = bound(initialTotal, 1, type(uint128).max);
        fp.maxVestTot = maximumTotal;
        fp.vestTau = bound(duration, 1, 20 * 365 days);
        fp.tau = cooldown;
        fp.vestBgn = block.timestamp + bound(startDelay, 1, 2 days);
        vm.prank(pauseProxy);
        ERC20Like(sky).approve(vest, allowance);
        _assertInitWithoutAccrual();
    }

    function testFarm_init_maximumTotalsAndMinimumDuration() public {
        fp.vestTot = type(uint128).max;
        fp.maxVestTot = type(uint128).max;
        fp.vestTau = 1;
        fp.vestBgn = block.timestamp;
        _assertInitWithoutAccrual();
    }

    function testFarm_init_minimumTotalAndMaximumDuration() public {
        uint256 cap = DssVestTransferrableLike(vest).cap();
        fp.vestTot = 1;
        fp.maxVestTot = 1;
        fp.vestTau = 20 * 365 days;
        fp.vestBgn = block.timestamp;
        _assertInitWithoutAccrual();
        assertEq(DssVestTransferrableLike(vest).cap(), cap); // The existing cap must not be lowered.
    }

    function testFarm_init_maximumCooldown() public {
        fp.tau = type(uint64).max;
        fp.vestBgn = block.timestamp;
        _assertInitWithoutAccrual();
    }

    function testFarm_init_futureStartUpperBoundary() public {
        fp.vestBgn = block.timestamp + 20 * 365 days;
        _assertInitReverts("DssVest/bgn-too-far");
        fp.vestBgn -= 1;
        _assertInitWithoutAccrual();
    }

    function testFarm_init_pastStartLowerBoundary() public {
        fp.vestBgn = block.timestamp - 20 * 365 days;
        _assertInitReverts("DssVest/bgn-too-long-ago");
        fp.vestBgn += 1;
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        FarmingInitResult memory result = _initFarm();
        assertEq(result.distributedAmount, fp.vestTot);
        assertEq(DssVestTransferrableLike(vest).rxd(result.vestId), fp.vestTot);
        assertEq(ERC20Like(sky).balanceOf(fp.rewards), fp.vestTot);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), treasuryBalance - fp.vestTot);
    }

    function testRevert_farm_init_extremeStartTimes() public {
        fp.vestBgn = 0;
        _assertInitReverts("DssVest/bgn-too-long-ago");
        fp.vestBgn = type(uint256).max;
        _assertInitReverts("DssVest/bgn-too-far");
    }

    function testFarm_init_preservesEqualCap() public {
        uint256 cap = (110 * fp.maxVestTot) / (100 * fp.vestTau);
        vm.prank(pauseProxy);
        VestConfigLike(vest).file("cap", cap);
        vm.expectCall(vest, abi.encodeWithSignature("file(bytes32,uint256)", bytes32("cap"), cap), uint64(0));
        _initFarm();
        assertEq(DssVestTransferrableLike(vest).cap(), cap);
    }

    function testFarm_init_duplicateFacilitators() public {
        fp.buds[1] = fp.buds[0];
        _initFarm();
        assertEq(RewardsBeamLike(fp.beam).buds(fp.buds[0]), 1);
        assertEq(RewardsBeamLike(fp.beam).wards(fp.buds[0]), 0);
        assertEq(DssVestTransferrableLike(vest).ids(), initialVestCount + 1);
    }

    function testFarm_init_facilitatorLists_Fuzz(uint8 count, uint256 seed) public {
        count = uint8(bound(count, 0, 8));
        fp.buds = new address[](count);
        for (uint256 i; i < count; i++) {
            // Generate nonzero addresses; duplicate handling is tested separately.
            fp.buds[i] = address(uint160(uint256(keccak256(abi.encode(seed, i)))) | uint160(1));
        }
        _initFarm();
        for (uint256 i; i < count; i++) {
            assertEq(RewardsBeamLike(fp.beam).buds(fp.buds[i]), 1);
        }
        assertEq(DssVestTransferrableLike(vest).ids(), initialVestCount + 1);
    }

    function testFarm_init_noFacilitatorsWithActiveMaximum() public {
        delete fp.buds;
        _initFarm();
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), fp.maxVestTot);
        assertEq(RewardsBeamLike(fp.beam).buds(address(0xB0B)), 0);
    }

    function testFarm_init_zeroMaximumWithFacilitators() public {
        fp.maxVestTot = 0;
        _initFarm();
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), 0);
        for (uint256 i; i < fp.buds.length; i++) {
            assertEq(RewardsBeamLike(fp.beam).buds(fp.buds[i]), 1);
        }
        assertEq(VestedRewardsDistributionLike(fp.dist).vestId(), initialVestCount + 1);
        assertEq(RewardsBeamLike(fp.beam).toc(), 0);
    }

    function testRevert_farm_init_missingVestPermission() public {
        vm.prank(pauseProxy);
        AuthLike(vest).deny(pauseProxy);
        _assertInitReverts("DssVest/not-authorized");
    }

    function testRevert_farm_init_missingDistributorPermission() public {
        vm.prank(pauseProxy);
        AuthLike(fp.dist).deny(pauseProxy);
        _assertInitReverts("VestedRewardsDistribution/not-authorized");
    }

    function testRevert_farm_init_missingBeamPermission() public {
        vm.prank(pauseProxy);
        RewardsBeamLike(fp.beam).deny(pauseProxy);
        _assertInitReverts("RewardsBeam/not-authorized");
    }

    function testRevert_farm_init_unavailableDependencies() public {
        for (uint256 field; field < 6; field++) {
            _assertUnavailableDependency(field, address(0));
            _assertUnavailableDependency(field, address(0xBAD));
        }
    }

    function _assertUnavailableDependency(uint256 field, address unavailable) internal {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        FarmingInitParams memory invalid = fp;
        if (field == 0) invalid.vest = unavailable;
        else if (field == 1) invalid.rewards = unavailable;
        else if (field == 2) invalid.dist = unavailable;
        else if (field == 3) invalid.beam = unavailable;
        else if (field == 4) invalid.mom = unavailable;
        else invalid.distJob = unavailable;
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (invalid)));
        _assertInitUnchanged(treasuryBalance, b);
    }

    function testRevert_farm_init_jobRejectsInterval() public {
        fp.distJobInterval = 0;
        // The job owns interval validation; any rejection must undo earlier funding and stream creation.
        vm.mockCallRevert(
            distJob,
            abi.encodeWithSignature("set(address,uint256)", fp.dist, fp.distJobInterval),
            abi.encodeWithSignature("Error(string)", "Job/invalid-interval")
        );
        _assertInitReverts("Job/invalid-interval");
    }

    function testRevert_farm_init_approvalReverts() public {
        vm.mockCallRevert(
            sky,
            abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max),
            abi.encodeWithSignature("Error(string)", "Token/approval-disabled")
        );
        _assertInitReverts("Token/approval-disabled");
    }

    function testRevert_farm_init_approvalHasInvalidReturnData() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        fp.vestBgn = block.timestamp + 1 days;
        vm.mockCall(sky, abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max), bytes(""));
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        _assertInitUnchanged(treasuryBalance, b);
        vm.mockCall(
            sky, abi.encodeWithSignature("approve(address,uint256)", vest, type(uint256).max), abi.encode(uint256(2))
        );
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        _assertInitUnchanged(treasuryBalance, b);
    }

    function testRevert_farm_init_replayBeforeStreamBegins() public {
        fp.vestBgn = block.timestamp + 1 days;
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        uint256 treasuryBalance = ERC20Like(sky).balanceOf(pauseProxy);
        assertEq(StakingRewardsLike(fp.rewards).rewardRate(), 0);
        _assertInitFailure("initFarm/rewards-distribution-already-set");
        assertEq(DssVestTransferrableLike(vest).ids(), initialVestCount + 1);
        assertEq(VestedRewardsDistributionLike(fp.dist).vestId(), initialVestCount + 1);
        assertEq(ERC20Like(sky).balanceOf(pauseProxy), treasuryBalance);
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);
    }

    function testFarm_init_futureStreamDoesNotDistribute() public {
        fp.vestBgn = block.timestamp + 1 days;
        vm.prank(pause);
        bytes memory data = ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        FarmingInitResult memory result = abi.decode(data, (FarmingInitResult));
        assertEq(result.distributedAmount, 0);
        assertEq(StakingRewardsLike(fp.rewards).rewardRate(), 0);
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), type(uint256).max);
        assertEq(RewardsBeamLike(fp.beam).maxVestTot(), fp.maxVestTot);
    }

    function testFarm_init_preservesHigherCap() public {
        vm.prank(pauseProxy);
        VestConfigLike(vest).file("cap", 100 ether);
        testFarm_init();
        assertEq(DssVestTransferrableLike(vest).cap(), 100 ether);
    }

    function testFarm_init_initialTotalAboveBeamMaximum() public {
        fp.maxVestTot = fp.vestTot / 2;
        testFarm_init();
    }

    function testFarm_init_withoutFacilitators() public {
        delete fp.buds;
        fp.maxVestTot = 0;
        testFarm_init();
        assertEq(RewardsBeamLike(fp.beam).buds(address(0xB0B)), 0);
    }

    function testRevert_farm_init_beamSanityChecks() public {
        _expectInitRevert(fp.beam, abi.encodeWithSignature("toc()"), abi.encode(uint128(1)));
        _expectInitRevert(fp.beam, abi.encodeWithSignature("dist()"), abi.encode(address(0xBAD)));
        _expectInitRevert(fp.beam, abi.encodeWithSignature("vest()"), abi.encode(address(0xBAD)));
        _expectInitRevert(fp.mom, abi.encodeWithSignature("beam()"), abi.encode(address(0xBAD)));
        _expectInitRevert(fp.mom, abi.encodeWithSignature("dist()"), abi.encode(address(0xBAD)));
        _expectInitRevert(fp.mom, abi.encodeWithSignature("vest()"), abi.encode(address(0xBAD)));
        _expectInitRevert(fp.mom, abi.encodeWithSignature("owner()"), abi.encode(address(0xBAD)));
        _expectInitRevert(fp.dist, abi.encodeWithSignature("stakingRewards()"), abi.encode(address(0xBAD)));
    }

    function testRevert_farm_init_requiresBeamAndMom() public {
        CheckInitFarmValuesBefore memory b = _checkFarm_init_beforeSpell(fp);
        address beam = fp.beam;
        fp.beam = address(0);
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));

        fp.beam = beam;
        fp.mom = address(0);
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        assertEq(DssVestTransferrableLike(vest).ids(), initialVestCount);
        assertEq(ERC20Like(sky).allowance(pauseProxy, vest), b.allowance);
    }

    function _expectInitRevert(address target, bytes memory callData, bytes memory returnData) internal {
        vm.mockCall(target, callData, returnData);
        vm.expectRevert("ds-pause-delegatecall-error");
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        vm.clearMockedCalls();
        assertEq(DssVestTransferrableLike(vest).ids(), initialVestCount);
        assertEq(AuthLike(vest).wards(fp.beam), 0);
    }

    function testFarm_init_wiresMomEmergencyStop() public {
        testFarm_init();
        uint256 id = VestedRewardsDistributionLike(fp.dist).vestId();
        vm.warp(block.timestamp + 1 days);
        vm.prank(ChiefLike(chainlog.getAddress("MCD_ADM")).hat());
        RewardsBeamMomLike(fp.mom).stop();
        assertEq(RewardsBeamLike(fp.beam).tau(), type(uint64).max);
        assertEq(DssVestTransferrableLike(vest).fin(id), block.timestamp);
    }
}

contract MockSpell {
    address immutable self = address(this);

    function initFarm(FarmingInitParams memory p) public returns (FarmingInitResult memory) {
        return TreasuryFundedFarmingInit.initFarm(p);
    }

    // Preserve the real Pause Proxy context while returning the initializer's exact failure to the test.
    function tryInitFarm(FarmingInitParams memory p) public returns (bool success, bytes memory data) {
        return self.delegatecall(abi.encodeCall(this.initFarm, (p)));
    }

    function initLockstakeFarm(FarmingInitParams memory p, address lockstakeEngine) public {
        TreasuryFundedFarmingInit.initLockstakeFarm(p, address(lockstakeEngine));
    }
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address addr);
}

interface ChiefLike {
    function hat() external view returns (address);
}

interface ProxyLike {
    function exec(address usr, bytes memory fax) external returns (bytes memory);
}

interface DssVestTransferrableLike {
    function cap() external view returns (uint256);
    function gem() external view returns (address);
    function ids() external view returns (uint256);
    function bgn(uint256 vestId) external view returns (uint256);
    function fin(uint256 vestId) external view returns (uint256);
    function rxd(uint256 vestId) external view returns (uint256);
    function tot(uint256 vestId) external view returns (uint256);
    function unpaid(uint256 vestId) external view returns (uint256);
}

interface StakingRewardsLike {
    function nominateNewOwner(address owner) external;
    function owner() external view returns (address);
    function rewardRate() external view returns (uint256);
    function rewardsDistribution() external view returns (address);
    function rewardsToken() external view returns (address);
    function stakingToken() external view returns (address);
}

interface VestedRewardsDistributionLike {
    function dssVest() external view returns (address);
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
}

interface RewardsBeamLike {
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
    function authority() external view returns (address);
    function stop() external;
}

interface VestConfigLike {
    function file(bytes32 what, uint256 data) external;
    function res(uint256 id) external view returns (uint256);
    function usr(uint256 id) external view returns (address);
}
