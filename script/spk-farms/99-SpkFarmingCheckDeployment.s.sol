// SPDX-FileCopyrightText: © 2023 Dai Foundation <www.daifoundation.org>
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

import {Script} from "forge-std/Script.sol";
import {ScriptTools} from "dss-test/ScriptTools.sol";
import {Reader} from "../helpers/Reader.sol";

contract SpkFarms_SpkFarmingCheckDeploymentScript is Script {
    function run() external returns (bool) {
        Reader deps = new Reader(ScriptTools.loadDependencies());

        address admin = deps.readAddress(".admin");
        address spk = deps.readAddress(".rewardsToken");
        address dist = deps.readAddress(".dist");
        address rewards = deps.readAddress(".rewards");
        address vest = deps.readAddress(".vest");
        address stakingToken = deps.readAddress(".stakingToken");

        require(WardsLike(vest).wards(admin) == 1, "DssVest/pause-proxy-not-ward");
        require(WardsLike(dist).wards(admin) == 1, "VestedRewardsDistribution/pause-proxy-not-ward");
        require(StakingRewardsLike(rewards).owner() == admin, "StakingRewards/admin-not-owner");

        require(VestedRewardsDistributionLike(dist).dssVest() == vest, "VestedRewardsDistribution/invalid-vest");
        require(VestedRewardsDistributionLike(dist).gem() == spk, "VestedRewardsDistribution/invalid-gem");
        require(
            VestedRewardsDistributionLike(dist).stakingRewards() == rewards,
            "VestedRewardsDistribution/invalid-staking-rewards"
        );

        require(StakingRewardsLike(rewards).rewardsToken() == spk, "StakingRewards/invalid-rewards-token");
        require(StakingRewardsLike(rewards).stakingToken() == stakingToken, "StakingRewards/invalid-staking-token");
        require(
            StakingRewardsLike(rewards).rewardsDistribution() == address(0),
            "StakingRewards/invalid-rewards-distribution"
        );

        require(DssVestWithGemLike(vest).gem() == spk, "DssVest/invalid-gem");

        return true;
    }
}

interface WardsLike {
    function wards(address who) external view returns (uint256);
}

interface VestedRewardsDistributionLike {
    function dssVest() external view returns (address);

    function stakingRewards() external view returns (address);

    function gem() external view returns (address);
}

interface StakingRewardsLike {
    function owner() external view returns (address);

    function stakingToken() external view returns (address);

    function rewardsToken() external view returns (address);

    function rewardsDistribution() external view returns (address);
}

interface DssVestWithGemLike {
    function gem() external view returns (address);
}
