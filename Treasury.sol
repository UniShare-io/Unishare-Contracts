// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import   './ContractGuard/ContractGuard.sol';
import   './Epoch/Epoch.sol';
import   './Library/FixedPoint.sol';
import   './Library/SafeERC20.sol';
import   './Library/Address.sol';
import   './Library/SafeMath.sol';
import   './Library/Safe112.sol';
import   './Library/Math.sol';
import   './Interface/IUniAsset.sol';
import   './Interface/IOracle.sol';
import   './Interface/ISimpleERCFund.sol';
import   './Interface/IBoardroom.sol';
/**
 * @title Uni Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of uni cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public fund;
    address public cash;
    address public bond;
    address public share;
    address public boardroom;

    address public bondOracle;
    address public seigniorageOracle;

    // ========== PARAMS
    uint256 public cashPriceOne;
    uint256 public cashPriceCeiling;
    uint256 public bondDepletionFloor;
    uint256 private accumulatedSeigniorage = 0;
    uint256 public fundAllocationRate = 8; // %

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _cash,
        address _bond,
        address _share,
        address _bondOracle,
        address _seigniorageOracle,
        address _boardroom,
        address _fund,
        uint256 _startTime
    ) public Epoch(1 days, _startTime, 0) {
        cash = _cash;
        bond = _bond;
        share = _share;
        bondOracle = _bondOracle;
        seigniorageOracle = _seigniorageOracle;

        boardroom = _boardroom;
        fund = _fund;

        cashPriceOne = 10**18;
        cashPriceCeiling = uint256(105).mul(cashPriceOne).div(10**2);

        bondDepletionFloor = uint256(1000).mul(cashPriceOne);
    }

    /* =================== Modifier =================== */

    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

        _;
    }

    modifier checkOperator {
        require(
            IUniAsset(cash).operator() == address(this) &&
                IUniAsset(bond).operator() == address(this) &&
                IUniAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // budget
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    // oracle
    function getBondOraclePrice() public view returns (uint256) {
        return _getCashPrice(bondOracle);
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
        return _getCashPrice(seigniorageOracle);
    }

    function _getCashPrice(address oracle) internal view returns (uint256) {
        try IOracle(oracle).consult(cash, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize() public checkOperator {
        require(!initialized, 'Treasury: initialized');

        // set accumulatedSeigniorage to it's balance
        accumulatedSeigniorage = IERC20(cash).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    function setFund(address newFund) public onlyOperator {
        fund = newFund;
        emit ContributionPoolChanged(msg.sender, newFund);
    }

    function setFundAllocationRate(uint256 rate) public onlyOperator {
        fundAllocationRate = rate;
        emit ContributionPoolRateChanged(msg.sender, rate);
    }

        // ORACLE
    function setBondOracle(address newOracle) public onlyOperator {
        address oldOracle = bondOracle;
        bondOracle = newOracle;
        emit BondOracleChanged(_msgSender(), oldOracle, newOracle);
    }

    function setSeigniorageOracle(address newOracle) public onlyOperator {
        address oldOracle = seigniorageOracle;
        seigniorageOracle = newOracle;
        emit SeigniorageOracleChanged(_msgSender(), oldOracle, newOracle);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCashPrice() internal {
        try IOracle(bondOracle).update()  {} catch {}
        try IOracle(seigniorageOracle).update()  {} catch {}
    }

    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot purchase bonds with zero amount');

        uint256 cashPrice = _getCashPrice(bondOracle);
        require(cashPrice == targetPrice, 'Treasury: cash price moved');
        require(
            cashPrice < cashPriceOne, // unc/uni < 1
            'Treasury: cashPrice not eligible for bond purchase'
        );

        uint256 bondPrice = cashPrice;

        IUniAsset(cash).burnFrom(msg.sender, amount);
        IUniAsset(bond).mint(msg.sender, amount.mul(1e18).div(bondPrice));
        _updateCashPrice();

        emit BoughtBonds(msg.sender, amount);
    }

    function redeemBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot redeem bonds with zero amount');

        uint256 cashPrice = _getCashPrice(bondOracle);
        require(cashPrice == targetPrice, 'Treasury: cash price moved');
        require(
            cashPrice > cashPriceCeiling, // unc/uni > 1.05
            'Treasury: cashPrice not eligible for bond purchase'
        );
        require(
            IERC20(cash).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );

        accumulatedSeigniorage = accumulatedSeigniorage.sub(
            Math.min(accumulatedSeigniorage, amount)
        );

        IUniAsset(bond).burnFrom(msg.sender, amount);
        IERC20(cash).safeTransfer(msg.sender, amount);
        _updateCashPrice();

        emit RedeemedBonds(msg.sender, amount);
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        if (cashPrice <= cashPriceCeiling) {
            return; // just advance epoch instead revert
        }

        // circulating supply
        uint256 cashSupply = IERC20(cash).totalSupply().sub(
            accumulatedSeigniorage
        );
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = cashSupply.mul(percentage).div(1e18);
        IUniAsset(cash).mint(address(this), seigniorage);

        // ======================== BIP-3
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            IERC20(cash).safeApprove(fund, fundReserve);
            ISimpleERCFund(fund).deposit(
                cash,
                fundReserve,
                'Treasury: Seigniorage Allocation'
            );
            emit ContributionPoolFunded(now, fundReserve);
        }

        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        uint256 treasuryReserve = Math.min(
            seigniorage,
            IERC20(bond).totalSupply().sub(accumulatedSeigniorage)
        );
        if (treasuryReserve > 0) {
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            emit TreasuryFunded(now, treasuryReserve);
        }

        // boardroom
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            IERC20(cash).safeApprove(boardroom, boardroomReserve);
            IBoardroom(boardroom).allocateSeigniorage(boardroomReserve);
            emit BoardroomFunded(now, boardroomReserve);
        }
    }

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(address indexed operator, address newFund);
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 newRate
    );
    event BondOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    event SeigniorageOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}