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
import {
    VestedRewardsDistributionInit, VestedRewardsDistributionInitParams
} from "../VestedRewardsDistributionInit.sol";

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
    uint256 vestTot;
    uint256 vestBgn;
    uint256 vestTau;
}

struct FarmingInitResult {
    uint256 vestId;
    uint256 distributedAmount;
}

library TreasuryFundedFarmingInit {
    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    function initFarm(FarmingInitParams memory p) internal returns (FarmingInitResult memory r) {
        require(DssVestWithGemLike(p.vest).gem() == p.rewardsToken, "initFarm/vest-gem-mismatch");

        require(
            StakingRewardsLike(p.rewards).stakingToken() == p.stakingToken, "initFarm/rewards-staking-token-mismatch"
        );
        require(
            StakingRewardsLike(p.rewards).rewardsToken() == p.rewardsToken, "initFarm/rewards-rewards-token-mismatch"
        );
        require(StakingRewardsLike(p.rewards).rewardRate() == 0, "initFarm/reward-rate-not-zero");
        require(
            StakingRewardsLike(p.rewards).rewardsDistribution() == address(0),
            "initFarm/rewards-distribution-already-set"
        );
        require(StakingRewardsLike(p.rewards).owner() == address(this), "initFarm/invalid-owner");

        require(VestedRewardsDistributionLike(p.dist).gem() == p.rewardsToken, "initFarm/dist-gem-mismatch");
        require(VestedRewardsDistributionLike(p.dist).dssVest() == p.vest, "initFarm/dist-dss-vest-mismatch");
        require(VestedRewardsDistributionLike(p.dist).vestId() == 0, "initFarm/dist-vest-id-already-set");
        require(
            VestedRewardsDistributionLike(p.dist).stakingRewards() == p.rewards,
            "initFarm/dist-staking-rewards-mismatch"
        );

        // Set `dist` with  `rewardsDistribution` role in `rewards`.
        StakingRewardsInit.init(p.rewards, StakingRewardsInitParams({dist: p.dist}));

        // Increase `rewardsToken` `p.vest` allowance from the treasury for `p.vestTot`.
        // Note: `p.vest` is expected to be of type `DssVestTransferrable`
        uint256 allowance = ERC20Like(p.rewardsToken).allowance(address(this), p.vest);
        ERC20Like(p.rewardsToken).approve(p.vest, allowance + p.vestTot);

        // Check if `p.vest.cap` needs to be adjusted based on the new vest rate.
        // Note: adds 10% buffer to the rate, as usual for this parameter.
        uint256 cap = DssVestWithGemLike(p.vest).cap();
        uint256 rateWithBuffer = (110 * (p.vestTot / p.vestTau)) / 100;
        if (rateWithBuffer > cap) {
            DssVestWithGemLike(p.vest).file("cap", rateWithBuffer);
        }

        // Create the proper vesting stream for rewards distribution.
        uint256 vestId = VestInit.create(
            p.vest, VestCreateParams({usr: p.dist, tot: p.vestTot, bgn: p.vestBgn, tau: p.vestTau, eta: 0})
        );

        // Set the `vestId` in `dist`
        VestedRewardsDistributionInit.init(p.dist, VestedRewardsDistributionInitParams({vestId: vestId}));

        // Check if the first distribution is already available and then distribute.
        uint256 unpaid = DssVestWithGemLike(p.vest).unpaid(vestId);
        if (unpaid > 0) {
            VestedRewardsDistributionLike(p.dist).distribute();
        }

        VestedRewardsDistributionJobLike(p.distJob).set(p.dist, p.distJobInterval);

        r.vestId = vestId;
        r.distributedAmount = unpaid;

        chainlog.setAddress(p.rewardsKey, p.rewards);
        chainlog.setAddress(p.distKey, p.dist);
    }

    function initLockstakeFarm(FarmingInitParams memory p) internal returns (FarmingInitResult memory r) {
        address lssky = chainlog.getAddress("LOCKSTAKE_SKY");
        address lse = chainlog.getAddress("LOCKSTAKE_ENGINE");
        require(p.stakingToken == lssky, "initLockstakeFarm/staking-token-not-lssky");

        r = initFarm(p);
        LockstakeEngineLike(lse).addFarm(p.rewards);
    }

    // TODO: add replacing of farm vest ID
}

interface WardsLike {
    function wards(address who) external view returns (uint256);
}

interface DssVestWithGemLike {
    function cap() external view returns (uint256);
    function gem() external view returns (address);
    function file(bytes32 key, uint256 value) external;
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
    function stakingRewards() external view returns (address);
    function vestId() external view returns (uint256);
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address addr) external;
}

interface ERC20Like {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external;
}

interface VestedRewardsDistributionJobLike {
    function set(address dist, uint256 interval) external;
}

interface LockstakeEngineLike {
    function addFarm(address farm) external;
}
