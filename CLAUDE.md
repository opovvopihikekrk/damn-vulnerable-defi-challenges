# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Damn Vulnerable DeFi is a Foundry-based CTF platform with intentionally vulnerable smart contracts covering DeFi attack vectors. The goal is to hack the vulnerable contracts in each challenge.

## Commands

```bash
# Build
forge build

# Run a single challenge test
forge test --mp test/<challenge-name>/<ChallengeName>.t.sol

# Run with transaction-limit enforcement (some challenges require this)
forge test --mp test/<challenge-name>/<ChallengeName>.t.sol --isolate

# Example
forge test --mp test/unstoppable/Unstoppable.t.sol
```

**Setup**: Copy `.env.sample` to `.env` and add a `MAINNET_FORKING_URL` — required for challenges that fork mainnet state.

## Architecture

### Challenge Structure

Each of the 19 challenges is self-contained:

```
src/<challenge-name>/   # Vulnerable contracts to analyze and exploit
test/<challenge-name>/  # Foundry test with setup, solution placeholder, and success checks
```

Shared token primitives live in `src/`: `DamnValuableToken` (DVT, ERC20+permit), `DamnValuableNFT`, `DamnValuableVotes`, `DamnValuableStaking`.

### Test Template Pattern

Every challenge test follows the same structure — the parts marked "DO NOT TOUCH" enforce invariants:

```solidity
contract ChallengeNameChallenge is Test {
    address deployer = makeAddr("deployer");
    address player   = makeAddr("player");     // your actor
    address recovery = makeAddr("recovery");   // funds must go here

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();   // validates success
    }

    function setUp() public { ... }                           // DO NOT TOUCH
    function test_assertInitialState() public { ... }         // initial condition checks
    function test_challengeName() public checkSolvedByPlayer { /* YOUR SOLUTION */ }
    function _isSolved() private { ... }                      // DO NOT TOUCH
}
```

### Solving a Challenge

- Write your exploit inside `test_<challengeName>()`, operating as `player`
- Rescued funds must be sent to the `recovery` address
- You may deploy helper contracts and use Foundry cheatcodes (`vm.warp`, `vm.roll`, `vm.prank`, etc.)
- Some challenges enforce a transaction limit via `vm.getNonce(player)` — use `--isolate` when testing those

### Key Dependencies (git submodules in `lib/`)

forge-std, OpenZeppelin Contracts v5 + Upgradeable, Uniswap v2 & v3, Safe Smart Account, Solmate, Solady, Murky, Permit2, Multicall
