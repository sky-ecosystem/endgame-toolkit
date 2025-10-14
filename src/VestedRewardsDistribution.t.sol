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

import {DssTest, stdStorage, StdStorage} from "dss-test/DssTest.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {DssVestWithGemLike} from "./interfaces/DssVestWithGemLike.sol";
import {IStakingRewards} from "./synthetix/interfaces/IStakingRewards.sol";
import {StakingRewards} from "./synthetix/StakingRewards.sol";
import {SDAO} from "./SDAO.sol";
import {VestedRewardsDistribution} from "./VestedRewardsDistribution.sol";

contract VestedRewardsDistributionTest is DssTest {
    using stdStorage for StdStorage;

    struct VestParams {
        address usr;
        uint256 tot;
        uint256 bgn;
        uint256 tau;
        uint256 eta;
    }

    struct DistributionParams {
        VestedRewardsDistribution dist;
        DssVestWithGemLike vest;
        IStakingRewards rewards;
        IERC20Mintable rewardsToken;
        uint256 vestId;
        VestParams vestParams;
    }

    DistributionParams k;

    uint256 constant DEFAULT_DURATION = 365 days;
    uint256 constant DEFAULT_CLIFF = 0;
    uint256 constant DEFAULT_STARTING_RATE = uint256(200_000 * WAD) / DEFAULT_DURATION;
    uint256 constant DEFAULT_FINAL_RATE = uint256(2_000_000 * WAD) / DEFAULT_DURATION;
    uint256 constant DEFAULT_TOTAL_REWARDS = ((DEFAULT_STARTING_RATE + DEFAULT_FINAL_RATE) * DEFAULT_DURATION) / 2;

    function setUp() public {
        // DssVest checks if params are not too far away in the future or in the past relative to `block.timestamp`.
        // It has a 20 years interval check hardcoded, so we need to be at a time that is at least 20 years ahead of
        // the Unix epoch.  We are setting the current date of the chain to 2000-01-01 to comply with that requirement.
        vm.warp(946692000);

        k = _setUpDistributionParams(
            DistributionParams({
                dist: VestedRewardsDistribution(address(0)),
                vest: DssVestWithGemLike(address(0)),
                rewards: IStakingRewards(address(0)),
                rewardsToken: IERC20Mintable(address(new SDAO("K Token", "K"))),
                vestId: 0,
                vestParams: _makeVestParams()
            })
        );
    }

    function testDistribute() public {
        // 1st distribution
        skip(k.vestParams.tau / 3);

        assertEq(k.rewardsToken.balanceOf(address(k.rewards)), 0, "Bad initial balance");

        vm.expectEmit(false, false, false, true, address(k.dist));
        emit Distribute(k.vestParams.tot / 3);
        k.dist.distribute();

        assertEq(
            k.rewardsToken.balanceOf(address(k.rewards)), k.vestParams.tot / 3, "Bad balance after 1st distribution"
        );

        // 2nd distribution
        skip(k.vestParams.tau / 3);

        vm.expectEmit(false, false, false, true, address(k.dist));
        emit Distribute(k.vestParams.tot / 3);
        k.dist.distribute();

        // Allow for 0,01% error tolerance due to rounding errors.
        uint256 tolerance = 0.0001e18;

        assertApproxEqRel(
            k.rewardsToken.balanceOf(address(k.rewards)),
            (2 * k.vestParams.tot) / 3,
            tolerance,
            "Bad balance after 2nd distribution"
        );

        // 3rd distribution
        skip(k.vestParams.tau / 3);

        vm.expectEmit(false, false, false, true, address(k.dist));
        emit Distribute(k.vestParams.tot / 3);
        k.dist.distribute();

        assertApproxEqRel(
            k.rewardsToken.balanceOf(address(k.rewards)),
            k.vestParams.tot,
            tolerance,
            "Bad balance after 3rd distribution"
        );
    }

    function testDistributeConstantFuzz(uint256 totalDistributions) public {
        // Anything between 1 per week and 1 per month.
        totalDistributions = (bound(totalDistributions, 12, 52) * k.vestParams.tau) / 365 days;
        // Make distributions uniformly spread across time
        uint256 timeSkip = k.vestParams.tau / totalDistributions;

        uint256[] memory balances = new uint256[](totalDistributions);
        vm.warp(k.vestParams.bgn);
        for (uint256 i = 0; i < totalDistributions; i++) {
            skip(timeSkip);
            k.dist.distribute();
            balances[i] = k.rewardsToken.balanceOf(address(k.rewards));
        }

        uint256[] memory deltas = new uint256[](totalDistributions - 1);
        for (uint256 i = 1; i < totalDistributions; i++) {
            deltas[i - 1] = balances[i] - balances[i - 1];
        }

        // Check the final balance. Allow for 0,01% error tolerance due to rounding errors.
        uint256 tolerance = 0.0001e18;

        // Check if balance grows at the same pace every time:
        for (uint256 i = 1; i < deltas.length; i++) {
            assertApproxEqRel(
                deltas[i],
                deltas[i - 1],
                tolerance,
                string.concat("Bad balance change between #", toString(i - 1), " and #", toString(i))
            );
        }

        assertApproxEqRel(k.rewardsToken.balanceOf(address(k.rewards)), k.vestParams.tot, tolerance);

        skip(365 days);
        // Check if the amount undistributed is less than 0.001% of the total
        assertLe(k.vest.unpaid(k.vestId), k.vestParams.tot / 10000);
    }

    function testRevertDistributeInvalidVestId() public {
        // We're `file`ing a valid `vestId` on `setUp`, so we need to revert it to its initial value
        stdstore.target(address(k.dist)).sig("vestId()").checked_write(bytes32(0));

        vm.expectRevert("VestedRewardsDistribution/invalid-vest-id");
        k.dist.distribute();
    }

    function testRevertDistributeNoVestedAmount() public {
        vm.expectRevert("VestedRewardsDistribution/no-pending-amount");
        k.dist.distribute();
    }

    function testRevertFileInvalidVestId() public {
        vm.expectRevert("VestedRewardsDistribution/invalid-vest-id");
        k.dist.file("vestId", 100);
    }

    function testRevertFileVestIdWithCliff() public {
        (uint256 vestId,) = _setUpVest(
            k.vest,
            VestParams({usr: address(k.dist), tot: 3_000_000 * WAD, bgn: block.timestamp, tau: 365 days, eta: 30 days})
        );
        vm.expectRevert("VestedRewardsDistribution/invalid-vest-cliff");
        k.dist.file("vestId", vestId);
    }

    function testRevertFileInvalidUsr() public {
        address usr = address(0x1337);
        (uint256 newVestId,) = _setUpVest(k.vest, usr);

        vm.expectRevert("VestedRewardsDistribution/invalid-vest-usr");
        k.dist.file("vestId", newVestId);
    }

    function testRevertFileInvalidRes() public {
        address usr = address(0x1337);
        (uint256 newVestId,) = _setUpVest(k.vest, usr, false);

        vm.expectRevert("VestedRewardsDistribution/invalid-vest-res");
        k.dist.file("vestId", newVestId);
    }

    function testAuth() public {
        checkAuth(address(k.dist), "VestedRewardsDistribution");
    }

    function testFile() public {
        // `checkFileUint` increments the current value of the param being modified.
        // Since `vestId` is validated, we need to create a new one to make sure the `file`d param is valid.
        // We also don't restrict the `vestId` on purpose to check whether `file` will do it or not.
        _setUpVest(k.vest, k.vestParams);
        checkFileUint(address(k.dist), "VestedRewardsDistribution", ["vestId"]);
        assertEq(k.dist.lastDistributedAt(), 0, "`lastDistributedAt` not reset");
    }

    function testDistributeFromMultipleVestsRegression() public {
        // 1st vest
        skip(k.vestParams.tau);

        assertEq(k.rewardsToken.balanceOf(address(k.rewards)), 0, "Bad initial balance");

        vm.expectEmit(false, false, false, true, address(k.dist));
        emit Distribute(k.vestParams.tot);
        k.dist.distribute();

        assertEq(k.rewardsToken.balanceOf(address(k.rewards)), k.vestParams.tot, "Bad balance after 1st distribution");

        // 2nd vest

        // We will create a vest that started 1 year ago and also have no cliff to check whether the distribute function
        // will send the total amount at once as it should.
        (uint256 vestId2, VestParams memory vestParams2) = _setUpVest(
            k.vest,
            VestParams({
                usr: address(k.dist),
                tot: k.vestParams.tot / 2,
                bgn: block.timestamp - k.vestParams.tau, // start in the past
                tau: k.vestParams.tau, // 1 year duration
                eta: 0 // No cliff; start immediatebly
            })
        );
        k.dist.file("vestId", vestId2);

        vm.expectEmit(false, false, false, true, address(k.dist));
        emit Distribute(vestParams2.tot);
        k.dist.distribute();

        assertEq(
            k.rewardsToken.balanceOf(address(k.rewards)),
            k.vestParams.tot + vestParams2.tot,
            "Bad balance after 2nd distribution"
        );

        // 3rd vest

        // We will create a vest that will only start to accrue in the future, so any calls to `distribute` should fail
        // before the elapsed time passes.

        (uint256 vestId3, VestParams memory vestParams3) = _setUpVest(
            k.vest,
            VestParams({
                usr: address(k.dist),
                tot: vestParams2.tot / 2,
                bgn: block.timestamp + k.vestParams.tau, // start in the future
                tau: k.vestParams.tau, // 1 year duration
                eta: 0 // No cliff; start immediatebly
            })
        );

        k.dist.file("vestId", vestId3);

        vm.expectRevert("VestedRewardsDistribution/no-pending-amount");
        k.dist.distribute();

        // After the initial time + the duration pass...
        vm.warp(vestParams3.bgn + vestParams3.tau);

        // We can claim the total amount `tot2` all at once.
        vm.expectEmit(false, false, false, true, address(k.dist));
        emit Distribute(vestParams3.tot);
        k.dist.distribute();

        assertEq(
            k.rewardsToken.balanceOf(address(k.rewards)),
            k.vestParams.tot + vestParams2.tot + vestParams3.tot,
            "Bad balance after 3rd distribution"
        );
    }

    function testUnexpectedTokenBalanceOnDistDoesNotMessWithDistributionRegression() public {
        // These tokens on the distribution contract should not be distributed.
        k.rewardsToken.mint(address(k.dist), 1_000_000_000 * WAD);

        skip(k.vestParams.tau / 3);

        assertEq(k.rewardsToken.balanceOf(address(k.rewards)), 0, "Bad initial balance");

        uint256 amount = k.dist.distribute();

        assertLt(amount, 1_000_000_000 * WAD, "Dangling tokens distributed");
        assertEq(k.rewardsToken.balanceOf(address(k.rewards)), amount, "Bad final balance");
    }

    function testRevertWithReasonWhenDistributeBeforeCliffRegression() public {
        (uint256 vestId2,) = _setUpVest(
            k.vest,
            VestParams({
                usr: address(k.dist),
                tot: k.vestParams.tot / 2,
                bgn: block.timestamp + 1 days, // start in the future
                tau: k.vestParams.tau, // 1 year duration
                eta: 0 // No cliff; start at bgn
            })
        );
        k.dist.file("vestId", vestId2);

        // Exactly at the cliff timestamp there should be no tokens to distribute
        skip(1 days);
        vm.expectRevert("VestedRewardsDistribution/no-pending-amount");
        k.dist.distribute();

        (uint256 vestId3,) = _setUpVest(
            k.vest,
            VestParams({
                usr: address(k.dist),
                tot: k.vestParams.tot / 2,
                bgn: block.timestamp + 1 days, // start in the future
                tau: k.vestParams.tau, // 1 year duration
                eta: 0 // No cliff; start at bgn
            })
        );
        k.dist.file("vestId", vestId3);

        // Exactly at the cliff timestamp there should be no tokens to distribute
        skip(1 days);
        vm.expectRevert("VestedRewardsDistribution/no-pending-amount");
        k.dist.distribute();
    }

    function _setUpDistributionParams(DistributionParams memory _distParams)
        internal
        returns (DistributionParams memory result)
    {
        result = _distParams;

        if (address(result.rewardsToken) == address(0)) {
            result.rewardsToken = IERC20Mintable(address(new SDAO("Token", "TKN")));
        }

        if (address(result.vest) == address(0)) {
            result.vest =
                DssVestWithGemLike(deployCode("DssVest.sol:DssVestMintable", abi.encode(address(result.rewardsToken))));
            result.vest.file("cap", type(uint256).max);
        }

        if (address(result.rewards) == address(0)) {
            result.rewards = new StakingRewards(address(this), address(0), address(result.rewardsToken), address(0));
        }

        if (address(result.dist) == address(0)) {
            result.dist = new VestedRewardsDistribution(address(result.vest), address(result.rewards));
        }

        result.rewards.setRewardsDistribution(address(result.dist));
        _distParams.vestParams.usr = address(result.dist);

        (result.vestId, result.vestParams) = _setUpVest(result.vest, _distParams.vestParams);
        result.dist.file("vestId", result.vestId);

        // Allow DssVest to mint tokens
        WardsLike(address(result.rewardsToken)).rely(address(result.vest));
    }

    function _setUpVest(DssVestWithGemLike _vest, address _usr)
        internal
        returns (uint256 _vestId, VestParams memory result)
    {
        return _setUpVest(_vest, _usr, true);
    }

    function _setUpVest(DssVestWithGemLike _vest, address _usr, bool restrict)
        internal
        returns (uint256 _vestId, VestParams memory result)
    {
        return _setUpVest(_vest, VestParams({usr: _usr, tot: 0, bgn: 0, tau: 0, eta: 0}), restrict);
    }

    function _setUpVest(DssVestWithGemLike _vest, VestParams memory _v)
        internal
        returns (uint256 _vestId, VestParams memory result)
    {
        return _setUpVest(_vest, _v, true);
    }

    function _setUpVest(DssVestWithGemLike _vest, VestParams memory _v, bool restrict)
        internal
        returns (uint256 _vestId, VestParams memory result)
    {
        result = _v;

        if (result.usr == address(0)) {
            revert("_setUpVest: usr not set");
        }
        if (result.tot == 0) {
            result.tot = DEFAULT_TOTAL_REWARDS;
        }
        if (result.bgn == 0) {
            result.bgn = block.timestamp;
        }
        if (result.tau == 0) {
            result.tau = DEFAULT_DURATION;
        }
        if (result.eta == 0) {
            result.eta = DEFAULT_CLIFF;
        }

        _vestId = _vest.create(result.usr, result.tot, result.bgn, result.tau, result.eta, address(0));
        if (restrict) {
            _vest.restrict(_vestId);
        }
    }

    function _makeVestParams() internal pure returns (VestParams memory) {
        return VestParams({usr: address(0), tot: 0, bgn: 0, tau: 0, eta: 0});
    }

    bytes16 private constant _SYMBOLS = "0123456789abcdef";

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Return the log in base 10, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    event Distribute(uint256 amount);
}

interface IERC20Mintable is IERC20 {
    function mint(address, uint256) external;
}

interface WardsLike {
    function rely(address) external;
}
