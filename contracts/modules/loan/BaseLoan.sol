pragma solidity ^0.8.9;

// Helpers
import { MutualUpgrade } from "../../utils/MutualUpgrade.sol";
import { LoanLib } from "../../utils/LoanLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// module interfaces 
import { ILoan } from "../../interfaces/ILoan.sol";
import { IEscrow } from "../../interfaces/IEscrow.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IInterestRate } from "../../interfaces/IInterestRate.sol";

abstract contract BaseLoan is ILoan, MutualUpgrade {  
  address immutable public borrower;   // borrower being lent to
  address immutable public oracle; 
  address immutable public arbiter;
  address immutable public interestRateModel;

  mapping(bytes32 => DebtPosition) public debts; // positionId -> DebtPosition
  bytes32[] positionIds; // all active positions

  // Loan Financials aggregated accross all existing  DebtPositions
  LoanLib.STATUS public loanStatus;

  // all deonminated in USD
  uint256 public principal; // initial loan  drawdown
  uint256 public totalInterestAccrued;// unpaid interest

  // i dont think we need to keep global var on this. only check per debt position
  uint256 immutable public maxDebtValue; // total amount of USD value to be pulled from loan


  /**
   * @dev - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
            Lender and borrower must both call function for MutualUpgrade to add debt position to Loan
   * @param maxDebtValue_ - total debt accross all lenders that borrower is allowed to create
   * @param oracle_ - price oracle to use for getting all token values
   * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
   * @param borrower_ - the debitor for all debt positions in this contract
   * @param interestRateModel_ - contract calculating lender interest from debt position values
  */
  constructor(
    uint256 maxDebtValue_,
    address oracle_,
    address arbiter_,
    address borrower_,
    address interestRateModel_
  ) {
    maxDebtValue = maxDebtValue_;

    borrower = borrower_;
    interestRateModel = interestRateModel_;
    arbiter = arbiter_;
    oracle = oracle_;

    loanStatus = LoanLib.STATUS.ACTIVE;
  }

  ///////////////
  // MODIFIERS //
  ///////////////

  modifier isActive() {
    require(loanStatus == LoanLib.STATUS.ACTIVE, 'Loan: no op');
    _;
  }

  modifier onlyBorrower() {
    require(msg.sender == borrower, 'Loan: only borrower');
    _;
  }

  modifier onlyArbiter() {
    require(msg.sender == arbiter, 'Loan: only arbiter');
    _;
  }

  modifier validPositionId(bytes32 positionId) {
    require(debts[positionId].lender != address(0), "Loan: invalid position ID");
    _;
  }
  ///////////
  // HOOKS //
  ///////////

  /**
   * @dev  Used to addc custom liquidation functionality until we create separate Liquidation module
   * @param positionId - deterministic id of loan
   * @param amount - expected amount of `targetToken` to be liquidated
   * @param targetToken - token to liquidate to repay debt
   * @return amount of tokens actually liquidated
  */
  function _liquidate(
    bytes32 positionId,
    uint256 amount,
    address targetToken
  )
    virtual internal
    returns(uint256)
  {
    return 0;
  }


  /**
   * @notice  Get amount of debt that borrower is currently allowed to repay.
   * @dev Modules can overwrite e.g. for bullet loans to prevent principal repayments
   * @param positionId - debt position data for loan being repaid
   * @param requestedRepayAmount - amount of debt that the borrower would like to pay
   * @return - amount borrower is allowedto repay. Returns 0 if repayment is not allowed
  */
  function _getMaxRepayableAmount(
    bytes32 positionId,
    uint256 requestedRepayAmount
  )
    virtual internal
    returns(uint256)
  {
    return requestedRepayAmount;
  }


  /**
   * @dev  Calls interestRate contract and gets amount of interest owned on debt position
   * @param positionId - debt position data for loan being calculated
   * @return total interest to add to position
  */
  function _getInterestPaymentAmount(bytes32 positionId)
    virtual internal
    returns(uint256)
  {
    return IInterestRate(interestRateModel).accrueInterest(
      positionId,
      debts[positionId].principal,
      loanStatus
    );
  }

  function healthcheck() external returns(LoanLib.STATUS) {
    // if loan is in a final end state then do not run _healthcheck()
    if(loanStatus == LoanLib.STATUS.REPAID || loanStatus == LoanLib.STATUS.INSOLVENT) {
      return loanStatus;
    }
    return _updateLoanStatus(_healthcheck());
  }
  /**
   *  @notice - loops through all modules and returns their status if required last to savegas on override external calls
   *        returns early if returns non-ACTIVE
  */
  function _healthcheck() virtual internal returns(LoanLib.STATUS status) {
    if(principal + totalInterestAccrued > maxDebtValue)
      return LoanLib.STATUS.OVERDRAWN;

    return loanStatus;
  }
  
  /**
  @dev Returns total debt obligation of borrower.
       Aggregated across all lenders.
       Denominated in USD.
  */
  function getOutstandingDebt() override external returns(uint256) {
    return principal + totalInterestAccrued;
  }

  /**
   * @dev - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
            Lender and borrower must both call function for MutualUpgrade to add debt position to Loan
   * @param amount - amount of `token` to initially deposit
   * @param token - the token to be lent out
   * @param lender - address that will manage debt position 
  */
  function addDebtPosition(
    uint256 amount,
    address token,
    address lender
  )
    isActive
    mutualUpgrade(lender, borrower) 
    override external
    returns(bool)
  {
    bytes32 positionId = LoanLib.computePositionId(address(this), lender, token);
    
    // MUST not double add position. otherwise we can not _close()
    require(debts[positionId].lender == address(0), 'Loan: position exists');

    bool success = IERC20(token).transferFrom(
      lender,
      address(this),
      amount
    );
    require(success, 'Loan: no tokens to lend');

    debts[positionId] = DebtPosition({
      lender: lender,
      token: token,
      principal: 0,
      interestAccrued: 0,
      deposit: amount
    });

    emit AddDebtPosition(lender, token, amount);

    // also add interest rate model here?
    return true;
  }
  
  /**
    @notice see _accrueInterest()
  */
  function accrueInterest() override external returns(uint256) {
    return _accrueInterest();
  }



  // Liquidation
  /**
   * @notice - Forcefully take collateral from borrower and repay debt for lender
   * @dev - only called by neutral arbiter party/contract
   * @dev - `loanStatus` must be LIQUIDATABLE
   * @param positionId -the debt position to pay down debt on
   * @param amount - amount of `targetToken` expected to be sold off in  _liquidate
   * @param targetToken - token that is expected to be sold of to repay positionId
   */

  function liquidate(
    bytes32 positionId,
    uint256 amount,
    address targetToken
  )
    onlyArbiter
    validPositionId(positionId)
    external
    returns(uint256)
  {
    require(loanStatus == LoanLib.STATUS.LIQUIDATABLE, "Loan: not liquidatable");
    return _liquidate(positionId, amount, targetToken);
  }


  ///////////////
  // REPAYMENT //
  ///////////////

  /**
   * @dev - Transfers token used in debt position from msg.sender to Loan contract.
   * @notice - see _repay() for more details
   * @param positionId -the debt position to pay down debt on
   * @param amount - amount of `token` in `positionId` to pay back
  */

  function depositAndRepay(
    bytes32 positionId,
    uint256 amount
  )
    validPositionId(positionId)
    override external
    returns(bool)
  {
    _accrueInterest();

    // TODO check if early repayment is allowed on loan
    uint256 amountToRepay = _getMaxRepayableAmount(positionId, amount);

    bool success = IERC20(debts[positionId].token).transferFrom(
      msg.sender,
      debts[positionId].lender,
      amountToRepay
    );
    require(success, 'Loan: failed repayment');

    _repay(positionId, amountToRepay);
    return true;
  }

   /**
   * @dev - Transfers enough tokens to repay entire debt position from `borrower` to Loan contract.
            Only callable by borrower bc it closes position.
   * @param positionId -the debt position to pay down debt on and close
  */
  function depositAndClose(bytes32 positionId)
    onlyBorrower
    validPositionId(positionId)
    override external
    returns(bool)
  {
    _accrueInterest();
    DebtPosition memory debt = debts[positionId];

    uint256 totalOwed = debt.principal + debt.interestAccrued;

    // borrwer deposits remaining balance not already repaid and held in contract
    bool success = IERC20(debt.token).transferFrom(
      msg.sender,
      address(this),
      totalOwed
    );
    require(success, 'Loan: deposit failed');

    require(_repay(positionId, totalOwed));
    require(_close(positionId));
    return true;
  }
  
  ////////////////////
  // FUND TRANSFERS //
  ////////////////////
     /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function borrow(bytes32 positionId, uint256 amount)
    isActive
    onlyBorrower
    validPositionId(positionId)
    override external
    returns(bool)
  {
    _accrueInterest();
    DebtPosition memory debt = debts[positionId];
    
    require(amount <= debt.deposit - debt.principal, 'Loan: no liquidity');

    debt.principal += amount;
    principal += _getTokenPrice(debt.token) * amount;
    // TODO call escrow contract and see if loan is still healthy before sending funds

    bool success = IERC20(debt.token).transferFrom(
      address(this),
      borrower,
      amount
    );
    require(success, 'Loan: borrow failed');


    emit Borrow(positionId, amount);

    return true;
  }

   /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function withdraw(bytes32 positionId, uint256 amount) override external returns(bool) {
    require(msg.sender == debts[positionId].lender);
    
    _accrueInterest();
    DebtPosition memory debt = debts[positionId];
    
    require(amount <  debt.deposit - debt.principal, 'Loan: no liquidity');

    debt.deposit -= amount;
    bool success = IERC20(debt.token).transferFrom(
      address(this),
      debt.lender,
      amount
    );
    require(success, 'Loan: withdraw failed');


    emit Withdraw(positionId, amount);

    return true;
  }


  /**
   * @dev - Deletes debt position preventing any more borrowing.
   *        Only callable by borrower or lender for debt position
   * @param positionId -the debt position to close
  */
  function close(bytes32 positionId) override external returns(bool) {
    DebtPosition memory debt = debts[positionId];
    require(
      msg.sender == debt.lender ||
      msg.sender == borrower
    );
    require(debt.principal + debt.interestAccrued == 0, 'Loan: close failed. debt owed');
    
    // repay lender initial deposit + accrued interest
    if(debt.deposit > 0) {
      require(IERC20(debt.token).transfer(debt.lender, debt.deposit));
    }

    require(_close(positionId));
    
    return true;
  }

  // prviliged interal functions
  /**
   * @dev - Reduces `principal` and/or `interestAccrued` on debt position, increases lender's `deposit`.
            Reduces global USD principal and totalInterestAccrued values.
            Expects checks for conditions of repaying and param sanitizing before calling
            e.g. early repayment of principal, tokens have actually been paid by borrower, etc.
   * @param positionId - debt position struct with all data pertaining to loan
   * @param amount - amount of token being repaid on debt position
  */
  function _repay(
    bytes32 positionId,
    uint256 amount
  )
    virtual internal
    returns(bool)
  {
    DebtPosition memory debt = debts[positionId];
    
    uint256 price = _getTokenPrice(debt.token);

    if(amount <= debt.interestAccrued) {
      debt.interestAccrued -= amount;
      totalInterestAccrued -= price * amount;
      emit RepayInterest(positionId, amount);
    } else {
      uint256 principalPayment = amount - debt.interestAccrued;
      // update global debt denominated in usd
      principal -= price * principalPayment;
      totalInterestAccrued -= price * debt.interestAccrued;

      emit RepayPrincipal(positionId, principalPayment);
      // update before set to 0
      emit RepayInterest(positionId, debt.interestAccrued);
      
      // update individual debt position denominated in token
      debt.principal -= principalPayment;
      // TODO update debt.deposit here or _accureInterest()?
      debt.interestAccrued = 0;
    }


    return true;
  }

  /**
   * @dev - Loops over all debt positions, calls InterestRate module with position data,
            then updates `interestAccrued` on position with returned data.
            Also updates global USD values for `totalInterestAccrued`.
            Can only be called when loan is not in distress
  */
  function _accrueInterest() isActive internal returns (uint256 accruedAmount) {
    uint256 len = positionIds.length;
    bytes32 id;
    DebtPosition memory debt;

    for(uint256 i = 0; i < len; i++) {
      id = positionIds[len];
      debt = debts[id];
      // get token demoninated interest accrued
      uint256 tokenIncrease = _getInterestPaymentAmount(id);

      // update debts balance
      debt.interestAccrued += tokenIncrease;
      // should we be increaseing deposit here or in _repay()?
      debt.deposit += tokenIncrease;

      // get USD value of interest accrued
      uint256 interestValue = _getTokenPrice(debt.token) * tokenIncrease;
      accruedAmount += interestValue;

      emit InterestAccrued(id, tokenIncrease, interestValue);
    }

    totalInterestAccrued += accruedAmount;
  }

  function _close(bytes32 positionId) internal returns(bool) {
    // remove from active list
    positionIds = LoanLib.removePosition(positionIds, positionId);

    // brick loan contract if all positions closed
    if(positionIds.length == 0) {
      loanStatus = LoanLib.STATUS.REPAID;
    }
    
    // emit event before data is deleted
    emit CloseDebtPosition(positionId);
    
    delete debts[positionId]; // yay gas refunds!!!

    return true;
  }

  // Helper functions
  function _updateLoanStatus(LoanLib.STATUS status) internal returns(LoanLib.STATUS) {
    loanStatus = status;
    emit UpdateLoanStatus(uint256(status));
    return status;
  }

  /**
   * @dev - Calls Oracle module to get most recent price for token.
            All prices denominated in USD.
   * @param token - token to get price for
  */
  function _getTokenPrice(address token) internal returns (uint256) {
    return IOracle(oracle).getLatestAnswer(token);
  }
}
