# Endgame Toolkit

A set of components for the [SubDAO](https://endgame.makerdao.com/subdaos/overview) stack in the context of the
[MakerDAO Endgame](https://endgame.makerdao.com/).

<!-- vim-markdown-toc GFM -->

- [Components](#components)
  - [`SubProxy`](#subproxy)
  - [`SDAO`](#sdao)
  - [Farms](#farms)
    - [`VestedRewardsDistribution`](#vestedrewardsdistribution)
    - [`StakingRewards`](#stakingrewards)
- [Contributing](#contributing)
  - [Requirements](#requirements)
  - [Install dependencies](#install-dependencies)
  - [Build](#build)
  - [Run tests](#run-tests)

<!-- vim-markdown-toc -->

## Components

### `SubProxy`

The `SubProxy` is the SubDAO level counter-party of the MakerDAO level [`MCD_PAUSE_PROXY`][mcd-pause-proxy]

The reason a Proxy is required is to isolate the context of execution for spells from the main governance contract to
avoid potential exploits messing with the original contract storage.

This module is heavily inspired by the original [`DSPauseProxy`][ds-pause-proxy] contract, with a few modifications:

- Instead of a single `owner`, it uses the now classic `wards`/`rely`/`deny` pattern from MCD.
- The `exec` function is `payable`.

### `SDAO`

`SDAO` is a standard ERC-20 token with permissioned `mint`ing capability. It is meant to be the main SubDAO governance
token.

There is an uncommon feature that allow the owner of the contract to change both `name` and `symbol`. This can be used
by SubDAOs in the future to rebrand their tokens. For simplicity, there is no limitation on the amount of times this can
be done at code level. Future immutability will be enforced off-chain by governance artifacts.

### Farms

For more details about the farming solution in the scope of the Endgame, please refer to the [technical document](https://hackmd.io/@dewiz/endgame-token-farming).

#### `VestedRewardsDistribution`

Rewards are going to be generated through a [`DssVestMintable`][dss-vest] contract and distributed to final users
through a [`StakingRewards`](#stakingrewards) contract.

`VestedRewardsDistribution` is the "glue" between these two very distinct contracts. It controls the vesting stream from
`DssVest` and permissionlessly allows for distributing rewards on a predefined schedule.

#### `StakingRewards`

`StakingRewards` is a port of [Synthetix `StakingRewards`][staking-rewards]. The changes made include:

- Upgrade to the Solidity version from 0.5.x to 0.8.x.
  - It was required some reorganization of the internal structure because of changes in the inheritance resolution
    mechanism.
- Add referral code functionality for `stake()`.
  - Referral codes are meant to be used by UIs to identify themselves as the preferred solution by users.
  - The original `stake(uint256 amount)` function still works the same as before.
  - There is a new overload `stake(uint256 amount, uint16 referral)` which performs the same operation and emits the
    new `Referral` event.
- Update `setRewardsDuration()` to support changing the reward duration during an active distribution.
  - This allows the duration to be changed even when new reward is added immediately after the end of a distribution
    period, which would be the case when `rewardDistribution` is a smart contract distributing new reward every period.
- Prevent `rewardsToken` and `stakingToken` from being the same token.
  - Instead of using the _pull pattern_, this contract expect the address with the `rewardsDistribution` role to
    transfer the tokens to it and call `notifyRewardAmount` with the correct value.
  - There is a possible scenario where the amount of tokens transferred to the contract is less than the amount used as
    a parameter in `notifyRewardAmount`. In such case, if the staking token and rewards token are the same, the staked
    tokens would be incorporated into the new reward period, causing stakers to lose their capital.

## Contributing

### Requirements

- [Foundry](https://github.com/foundry-rs/foundry)
- [Node.js](https://nodejs.org/)
- [Yarn 1.x](https://classic.yarnpkg.com/lang/en/)

We use Foundry for all Solidity things and Node.js + Yarn to manage devtools, such as linting and formatting.

### Install dependencies

After cloning the repo, run:

```bash
# 1. Install solhint, prettier, husky and other tools
yarn install
# 2. Install Foundry dependencies
forge update
```

### Build

**⚠️ ATTENTION:** The order of execution is important here.

```bash
# 1. Build the Solidity 0.6.x contract
FOUNDRY_PROFILE=0_6_x forge build
# 2. Build the default Solidity 0.8.x contracts
forge build
```

Notice that if you use `forge build --force`, the `out/` directory is going to be erased.

### Run tests

```bash
forge test -vvv
```

[mcd-pause-proxy]: https://etherscan.io/address/0xbe8e3e3618f7474f8cb1d074a26affef007e98fb#code
[dss-vest]: https://github.com/makerdao/dss-vest/blob/19a9d663bb3a2737f1f0c763365f1dfc6788aad2/src/DssVest.sol#L223-L225
[ds-pause-proxy]: https://github.com/makerdao/ds-pause/blob/5e798dd96bfaac978cd9fe3c0259b486e8afd213/src/pause.sol#L139-L154
[staking-rewards]: https://github.com/Synthetixio/synthetix/blob/098b7f58a65fab5c2608d1d7e9c8bd56fdcc50d3/contracts/StakingRewards.sol

## Audits

Audit reports are hosted on the auditors' public portfolio pages:

| Auditor | Report | Date |
| --- | --- | --- |
| ChainSecurity | [Sky Endgame Toolkit](https://www.chainsecurity.com/security-audit/maker-endgame-toolkit/) | 2026-01-16 |
| Cantina | [Sky: Endgame Toolkit](https://cantina.xyz/portfolio/5c4e6fc9-91db-41dc-860e-101d093bce47) | 2025-11-28 |
| Cantina | [sdao](https://cantina.xyz/portfolio/9543ae20-3e91-42d3-86f2-b40a480f1bb6) | 2024-09-17 |
| Cantina | [endgame-toolkit (updates)](https://cantina.xyz/portfolio/24a166ef-0910-4d89-b4f9-8932632f6b98) | 2024-09-02 |
| Cantina | [endgametoolkit](https://cantina.xyz/portfolio/b6a73f6e-046f-41de-81ee-ac29b2791bbd) | 2023-09-25 |

ChainSecurity reports are cumulative: each portfolio page hosts the latest version of the report, which covers all previously reviewed versions.
