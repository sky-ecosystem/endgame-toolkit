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

import {StakingRewardsInit, StakingRewardsInitParams} from "../StakingRewardsInit.sol";
import {VestInit, VestCreateParams} from "../VestInit.sol";
import {VestedRewardsDistributionInit, VestedRewardsDistributionInitParams} from "../VestedRewardsDistributionInit.sol";

struct FarmingInitParams {
    address stakingToken;
    address rewardsToken;
    address rewards;
    bytes32 rewardsKey; // Chainlog key
    address dist;
    bytes32 distKey; // Chainlog key
    address distJob;
    uint256 distJobInterval; // in seconds
    address vest;
    uint256 vestTot; // wad
    uint256 vestBgn; // unix timestamp
    uint256 vestTau; // in seconds
    address beam;
    bytes32 beamKey; // Chainlog key
    address mom;
    bytes32 momKey; // Chainlog key
    address[] buds; // Facilitators allowed to call beam.set()
    uint256 maxVestTot; // token decimals precision; maximum total per beam stream
    uint256 tau; // beam cooldown in seconds
}

struct FarmingInitResult {
    uint256 vestId;
    uint256 distributedAmount;
}

library TreasuryFundedFarmingInit {
    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    function initFarm(FarmingInitParams memory p) internal returns (FarmingInitResult memory r) {
        require(p.vestTot > 0, "initFarm/vest-tot-zero");
        require(p.vestTot <= type(uint128).max, "initFarm/vest-tot-too-large");
        require(p.maxVestTot <= type(uint128).max, "initFarm/max-vest-tot-too-large");
        require(p.vestTau > 0, "initFarm/vest-tau-zero");
        require(p.tau <= type(uint64).max, "initFarm/invalid-tau");
        require(
            p.rewardsKey != bytes32(0) && p.distKey != bytes32(0) && p.beamKey != bytes32(0) && p.momKey != bytes32(0),
            "initFarm/zero-chainlog-key"
        );
        require(
            p.rewardsKey != p.distKey && p.rewardsKey != p.beamKey && p.rewardsKey != p.momKey && p.distKey != p.beamKey
                && p.distKey != p.momKey && p.beamKey != p.momKey,
            "initFarm/duplicate-chainlog-key"
        );

        DssVestTransferrableLike vest = DssVestTransferrableLike(p.vest);
        // Note: `p.vest` is expected to be of type `DssVestTransferrable`
        require(vest.czar() == address(this), "initFarm/vest-czar-mismatch");
        require(vest.gem() == p.rewardsToken, "initFarm/vest-gem-mismatch");
        require(p.vestTau <= vest.TWENTY_YEARS(), "initFarm/vest-tau-too-long");

        {
            StakingRewardsLike rewards = StakingRewardsLike(p.rewards);
            require(rewards.stakingToken() == p.stakingToken, "initFarm/rewards-staking-token-mismatch");
            require(rewards.rewardsToken() == p.rewardsToken, "initFarm/rewards-rewards-token-mismatch");
            require(rewards.rewardRate() == 0, "initFarm/reward-rate-not-zero");
            require(rewards.rewardsDistribution() == address(0), "initFarm/rewards-distribution-already-set");
            require(rewards.owner() == address(this), "initFarm/invalid-owner");
            require(rewards.nominatedOwner() == address(0), "initFarm/pending-owner");
        }

        VestedRewardsDistributionLike dist = VestedRewardsDistributionLike(p.dist);
        require(dist.gem() == p.rewardsToken, "initFarm/dist-gem-mismatch");
        require(dist.dssVest() == p.vest, "initFarm/dist-dss-vest-mismatch");
        require(dist.vestId() == 0, "initFarm/dist-vest-id-already-set");
        require(dist.stakingRewards() == p.rewards, "initFarm/dist-staking-rewards-mismatch");

        RewardsBeamLike beam = RewardsBeamLike(p.beam);
        require(beam.toc() == 0, "initFarm/beam-toc-not-zero");
        require(beam.dist() == p.dist, "initFarm/beam-dist-mismatch");
        require(beam.vest() == p.vest, "initFarm/beam-vest-mismatch");

        RewardsBeamMomLike mom = RewardsBeamMomLike(p.mom);
        require(mom.beam() == p.beam, "initFarm/mom-beam-mismatch");
        require(mom.dist() == p.dist, "initFarm/mom-dist-mismatch");
        require(mom.vest() == p.vest, "initFarm/mom-vest-mismatch");
        require(mom.owner() == address(this), "initFarm/mom-owner-mismatch");

        // Set `dist` with `rewardsDistribution` role in `rewards`.
        StakingRewardsInit.init(p.rewards, StakingRewardsInitParams({dist: p.dist}));
        ERC20Like rewardsToken = ERC20Like(p.rewardsToken);

        // Set `rewardsToken` `p.vest` allowance from the treasury to the maximum for future stream replacements.
        // Note: the beam cannot adjust the treasury's allowance.
        require(rewardsToken.approve(p.vest, type(uint256).max), "initFarm/rewards-approve-failed");
        require(
            rewardsToken.allowance(address(this), p.vest) == type(uint256).max, "initFarm/rewards-allowance-mismatch"
        );

        // Accommodate both the initial rate and the maximum configured beam rate.
        // Note: adds 10% buffer to the rate, as usual for this parameter.
        {
            uint256 cap = vest.cap();
            uint256 maxTot = p.vestTot > p.maxVestTot ? p.vestTot : p.maxVestTot;
            uint256 rateWithBuffer = (110 * maxTot) / (100 * p.vestTau);
            if (rateWithBuffer > cap) {
                vest.file("cap", rateWithBuffer);
            }
        }

        // Create the proper vesting stream for rewards distribution.
        uint256 vestId = VestInit.create(
            p.vest, VestCreateParams({usr: p.dist, tot: p.vestTot, bgn: p.vestBgn, tau: p.vestTau, eta: 0})
        );

        // Set the `vestId` in `dist`
        VestedRewardsDistributionInit.init(p.dist, VestedRewardsDistributionInitParams({vestId: vestId}));

        // Check if the first distribution is already available and then distribute.
        uint256 unpaid = vest.unpaid(vestId);
        if (unpaid > 0) {
            dist.distribute();
        }

        VestedRewardsDistributionJobLike distJob = VestedRewardsDistributionJobLike(p.distJob);
        distJob.set(p.dist, p.distJobInterval);

        r.vestId = vestId;
        r.distributedAmount = unpaid;

        // Match RewardsBeamInit: the initial stream must exist before enabling stream replacement.
        vest.rely(p.beam);
        dist.rely(p.beam);
        beam.rely(p.mom);
        vest.rely(p.mom);

        beam.file("maxVestTot", p.maxVestTot);
        beam.file("vestTau", p.vestTau);
        beam.file("tau", p.tau);
        for (uint256 i; i < p.buds.length; i++) {
            require(p.buds[i] != address(0), "initFarm/zero-facilitator");
            beam.kiss(p.buds[i]);
        }

        // Resolve the authority before writing any caller-supplied Chainlog keys.
        {
            address chief = chainlog.getAddress("MCD_ADM");
            require(chief.code.length > 0, "initFarm/invalid-chief");
            mom.setAuthority(chief);
        }

        chainlog.setAddress(p.rewardsKey, p.rewards);
        chainlog.setAddress(p.distKey, p.dist);
        chainlog.setAddress(p.beamKey, p.beam);
        chainlog.setAddress(p.momKey, p.mom);
    }

    function initLockstakeFarm(FarmingInitParams memory p, address lockstakeEngine)
        internal
        returns (FarmingInitResult memory r)
    {
        address lssky = LockstakeEngineLike(lockstakeEngine).lssky();
        require(p.stakingToken == lssky, "initLockstakeFarm/staking-token-not-lssky");
        r = initFarm(p);
        LockstakeEngineLike(lockstakeEngine).addFarm(p.rewards);
    }
}

interface DssVestTransferrableLike {
    function TWENTY_YEARS() external view returns (uint256);
    function cap() external view returns (uint256);
    function czar() external view returns (address);
    function gem() external view returns (address);
    function file(bytes32 key, uint256 value) external;
    function unpaid(uint256 vestId) external view returns (uint256);
    function rely(address usr) external;
}

interface StakingRewardsLike {
    function nominatedOwner() external view returns (address);
    function owner() external view returns (address);
    function rewardRate() external view returns (uint256);
    function rewardsDistribution() external view returns (address);
    function rewardsToken() external view returns (address);
    function stakingToken() external view returns (address);
}

interface VestedRewardsDistributionLike {
    function rely(address usr) external;
    function dssVest() external view returns (address);
    function distribute() external;
    function gem() external view returns (address);
    function stakingRewards() external view returns (address);
    function vestId() external view returns (uint256);
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address addr) external;
}

interface ERC20Like {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface VestedRewardsDistributionJobLike {
    function set(address dist, uint256 interval) external;
}

interface LockstakeEngineLike {
    function addFarm(address farm) external;
    function lssky() external view returns (address);
}

interface RewardsBeamLike {
    function dist() external view returns (address);
    function vest() external view returns (address);
    function toc() external view returns (uint128);
    function file(bytes32 what, uint256 data) external;
    function kiss(address usr) external;
    function rely(address usr) external;
}

interface RewardsBeamMomLike {
    function beam() external view returns (address);
    function dist() external view returns (address);
    function vest() external view returns (address);
    function owner() external view returns (address);
    function setAuthority(address authority) external;
}
