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

contract TreasuryFundedFarmingInitIntegrationTest is DssTest {
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

    function _deployBeam(FarmingInitParams storage p) internal {
        p.beam = deployCode("RewardsBeam.sol:RewardsBeam", abi.encode(p.dist));
        p.mom = deployCode("RewardsBeamMom.sol:RewardsBeamMom", abi.encode(p.beam));
        RewardsBeamLike(p.beam).rely(pauseProxy);
        RewardsBeamLike(p.beam).deny(address(this));
        RewardsBeamMomLike(p.mom).setOwner(pauseProxy);
        p.buds[0] = address(0xB0B);
        p.buds[1] = address(0xB0B2);
    }

    function testInitFarm_stakeGetRewardAndWithdraw_Fuzz(uint256 stakeAmt) public {
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
        assertEq(stakedBalance, pstakedBalance + stakeAmt, "Staking failed: balance should increase by staked amount");

        // Accumulate rewards.
        vm.warp(block.timestamp + 1 days);

        // Check earned rewards.
        uint256 earnedAmt = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedAmt, 0, "No rewards earned after 1 day of staking");

        // Claim earned rewards.
        uint256 prewardsTokenBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).getReward();
        uint256 rewardsTokenBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        assertEq(
            rewardsTokenBalance,
            prewardsTokenBalance + earnedAmt,
            "Reward claiming failed: balance should increase by earned amount"
        );

        // Withdraw staked tokens.
        uint256 pstakingTokenBalance = ERC20Like(fp.stakingToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).withdraw(stakeAmt);
        uint256 stakingTokenBalance = ERC20Like(fp.stakingToken).balanceOf(usr);
        assertEq(
            stakingTokenBalance,
            pstakingTokenBalance + stakeAmt,
            "Withdrawal failed: balance should increase by withdrawn amount"
        );
    }

    function testInitLockstakeFarm_openSelectFarmLockGetRewardAndFree_Fuzz(uint256 lockAmt) public {
        // Bound lockAmt to [1, 1_000_000_000_000]
        lockAmt = bound(lockAmt, 1 * 10 ** 18, 1_000_000_000_000 * 10 ** 18);

        // Simulate spell casting
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initLockstakeFarm, (lfp, lockstakeEngine)));

        // Open a new urn
        address owner = address(this);

        uint256 ownerUrnsCount = LockstakeEngineLike(lockstakeEngine).ownerUrnsCount(owner);
        assertEq(ownerUrnsCount, 0, "Owner should start with zero urns");

        uint256 urnIndex = ownerUrnsCount;
        address urn = LockstakeEngineLike(lockstakeEngine).open(urnIndex);

        // Select a farm
        LockstakeEngineLike(lockstakeEngine).selectFarm(owner, urnIndex, lfp.rewards, 0);
        assertEq(
            LockstakeEngineLike(lockstakeEngine).urnFarms(urn),
            lfp.rewards,
            "Farm selection failed: urn should be associated with rewards contract"
        );

        // Lock tokens
        address lockToken = LockstakeEngineLike(lockstakeEngine).sky();
        deal(address(lockToken), owner, lockAmt);

        ERC20Like(lockToken).approve(lockstakeEngine, type(uint256).max);
        LockstakeEngineLike(lockstakeEngine).lock(owner, urnIndex, lockAmt, 0);

        // Check staking token balance for the urn
        uint256 stakedAmt = StakingRewardsLike(lfp.rewards).balanceOf(urn);
        assertEq(stakedAmt, lockAmt, "Lockstake failed: urn staked balance should equal locked amount");

        // Accumulate rewards
        vm.warp(block.timestamp + 1 days);

        // Check earned rewards
        uint256 earnedAmt = StakingRewardsLike(lfp.rewards).earned(urn);
        assertGt(earnedAmt, 0, "No rewards earned after 1 day of lockstaking");

        // Get rewards
        uint256 prewardsTokenBalance = ERC20Like(lfp.rewardsToken).balanceOf(owner);
        LockstakeEngineLike(lockstakeEngine).getReward(owner, urnIndex, lfp.rewards, owner);
        uint256 rewardsTokenBalance = ERC20Like(lfp.rewardsToken).balanceOf(owner);
        assertEq(
            rewardsTokenBalance,
            prewardsTokenBalance + earnedAmt,
            "Lockstake reward claiming failed: balance should increase by earned amount"
        );

        // Free urn
        uint256 plockTokenBalance = ERC20Like(lockToken).balanceOf(owner);
        LockstakeEngineLike(lockstakeEngine).free(owner, urnIndex, owner, lockAmt);
        uint256 lockTokenBalance = ERC20Like(lockToken).balanceOf(owner);
        assertEq(
            lockTokenBalance,
            plockTokenBalance + lockAmt,
            "Free operation failed: balance should increase by freed amount"
        );
    }

    function testRewardsBeam_integration_stakingStillWorksAfterStreamReplacement() public {
        uint256 stakeAmt = 1000 * 10 ** 18;

        // Initialize farm
        vm.prank(pause);
        ProxyLike(pauseProxy).exec(address(spell), abi.encodeCall(spell.initFarm, (fp)));
        assertEq(ERC20Like(fp.rewardsToken).allowance(pauseProxy, fp.vest), type(uint256).max);

        // Set up staking
        address usr = address(this);
        deal(address(fp.stakingToken), usr, stakeAmt);
        ERC20Like(fp.stakingToken).approve(fp.rewards, stakeAmt);
        StakingRewardsLike(fp.rewards).stake(stakeAmt);

        // Accumulate some rewards
        assertEq(StakingRewardsLike(fp.rewards).earned(usr), 0, "No rewards should be earned before time advances");
        vm.warp(block.timestamp + 2 days);
        uint256 earnedBefore = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedBefore, 0, "No rewards earned before stream replacement");

        // The authorized facilitator replaces the vesting stream without an executive spell.
        {
            uint256 prevId = VestedRewardsDistributionLike(fp.dist).vestId();
            vm.prank(fp.buds[0]);
            RewardsBeamLike(fp.beam).set(1_200_000 * 10 ** 18);
            uint256 id = VestedRewardsDistributionLike(fp.dist).vestId();
            assertEq(id, prevId + 1, "Stream replacement should create exactly one new stream");
            assertEq(DssVestTransferrableLike(fp.vest).fin(prevId), block.timestamp, "Old stream should be yanked");
            assertEq(DssVestTransferrableLike(fp.vest).usr(id), fp.dist, "New stream should fund this distributor");
            assertEq(DssVestTransferrableLike(fp.vest).res(id), 1, "New stream should be restricted");
            assertEq(DssVestTransferrableLike(fp.vest).tot(id), 1_200_000 * 10 ** 18, "New stream total mismatch");
            assertEq(DssVestTransferrableLike(fp.vest).bgn(id), block.timestamp, "New stream should begin now");
            assertEq(
                DssVestTransferrableLike(fp.vest).fin(id), block.timestamp + fp.vestTau, "New stream duration mismatch"
            );
            assertEq(DssVestTransferrableLike(fp.vest).rxd(id), 0, "New stream should not have paid immediately");
        }

        // Accumulate rewards in the replacement stream.
        vm.warp(block.timestamp + 7 days);

        // Transfer actual tokens from the replacement stream through the mainnet vest into the farm.
        {
            uint256 id = VestedRewardsDistributionLike(fp.dist).vestId();
            uint256 unpaid = DssVestTransferrableLike(fp.vest).unpaid(id);
            uint256 farmBalance = ERC20Like(fp.rewardsToken).balanceOf(fp.rewards);
            uint256 treasuryBalance = ERC20Like(fp.rewardsToken).balanceOf(pauseProxy);
            assertGt(unpaid, 0, "Replacement stream should have accrued rewards");
            assertEq(VestedRewardsDistributionLike(fp.dist).distribute(), unpaid, "Replacement distribution mismatch");
            assertEq(
                DssVestTransferrableLike(fp.vest).rxd(id),
                unpaid,
                "Replacement stream should have paid the distribution"
            );
            assertEq(ERC20Like(fp.rewardsToken).balanceOf(fp.rewards), farmBalance + unpaid, "Farm funding mismatch");
            assertEq(
                ERC20Like(fp.rewardsToken).balanceOf(pauseProxy), treasuryBalance - unpaid, "Treasury funding mismatch"
            );
            assertEq(ERC20Like(fp.rewardsToken).allowance(pauseProxy, fp.vest), type(uint256).max);
        }

        // Accumulate more rewards, claim the full amount, then recover the stake.
        vm.warp(block.timestamp + 1 days);
        uint256 earnedAfter = StakingRewardsLike(fp.rewards).earned(usr);
        assertGt(earnedAfter, earnedBefore, "Rewards should continue accumulating after stream replacement");
        uint256 preBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        StakingRewardsLike(fp.rewards).getReward();
        uint256 postBalance = ERC20Like(fp.rewardsToken).balanceOf(usr);
        assertEq(postBalance, preBalance + earnedAfter, "Rewards claim mismatch");
        StakingRewardsLike(fp.rewards).withdraw(stakeAmt);
        assertEq(StakingRewardsLike(fp.rewards).balanceOf(usr), 0, "All stake should be withdrawn");
        assertEq(ERC20Like(fp.stakingToken).balanceOf(usr), stakeAmt, "Withdrawn stake mismatch");
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
    function bgn(uint256 id) external view returns (uint256);
    function fin(uint256 id) external view returns (uint256);
    function res(uint256 id) external view returns (uint256);
    function rxd(uint256 id) external view returns (uint256);
    function tot(uint256 id) external view returns (uint256);
    function unpaid(uint256 id) external view returns (uint256);
    function usr(uint256 id) external view returns (address);
}

interface VestedRewardsDistributionLike {
    function distribute() external returns (uint256);
    function vestId() external view returns (uint256);
}

interface StakingRewardsLike {
    function balanceOf(address who) external view returns (uint256);
    function earned(address who) external view returns (uint256);
    function getReward() external;
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
}

interface ERC20Like {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external;
    function balanceOf(address who) external view returns (uint256);
}

interface LockstakeEngineLike {
    function free(address owner, uint256 urnIndex, address to, uint256 wad) external;
    function getReward(address owner, uint256 index, address farm, address to) external returns (uint256 amt);
    function lock(address owner, uint256 urnIndex, uint256 wad, uint16 ref) external;
    function open(uint256 urnIndex) external returns (address urn);
    function ownerUrnsCount(address owner) external view returns (uint256);
    function selectFarm(address owner, uint256 urnIndex, address farm, uint16 ref) external;
    function sky() external view returns (address);
    function urnFarms(address urn) external view returns (address);
}

interface RewardsBeamLike {
    function rely(address usr) external;
    function deny(address usr) external;
    function set(uint256 vestTot) external;
}

interface RewardsBeamMomLike {
    function setOwner(address owner) external;
}
