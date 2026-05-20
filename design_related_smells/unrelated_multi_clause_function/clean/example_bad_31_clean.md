```elixir
defmodule LoanProcessor do
  @moduledoc """
  Core loan processing engine for the lending platform.
  Handles new loan applications, credit limit adjustments, and
  early repayment processing for existing loan accounts.
  """

  alias LoanProcessor.{
    LoanApplication,
    CreditAdjustmentRequest,
    EarlyRepaymentRequest,
    CreditBureau,
    UnderwritingEngine,
    LoanStore,
    AccountStore,
    PaymentProcessor,
    RegulatoryReporter,
    CustomerMailer
  }

  require Logger

  @doc """
  Evaluate a lending operation request.

  Accepts a `%LoanApplication{}`, `%CreditAdjustmentRequest{}`, or
  `%EarlyRepaymentRequest{}` and performs the corresponding lending workflow.

  ## Examples

      iex> LoanProcessor.evaluate(%LoanApplication{customer_id: 1, amount: 10_000_00, term_months: 36})
      {:ok, %{decision: :approved, loan_id: "loan_001", rate: 0.089}}

  """
  def evaluate(%LoanApplication{
        customer_id: customer_id,
        amount: amount,
        term_months: term_months,
        purpose: purpose,
        income: income
      })
      when amount > 0 and term_months in [12, 24, 36, 48, 60] do
    with {:ok, bureau_report} <- CreditBureau.pull_report(customer_id),
         {:ok, decision} <-
           UnderwritingEngine.evaluate(%{
             credit_score: bureau_report.score,
             debt_to_income: bureau_report.dti,
             income: income,
             requested_amount: amount,
             term_months: term_months,
             purpose: purpose
           }),
         {:ok, loan} <- maybe_create_loan(decision, customer_id, amount, term_months, decision.rate),
         :ok <- RegulatoryReporter.submit_application(customer_id, amount, decision),
         :ok <- CustomerMailer.send_loan_decision(customer_id, decision, loan) do
      Logger.info("Loan application for customer #{customer_id}: #{decision.status}")
      {:ok, %{decision: decision.status, loan_id: loan && loan.id, rate: decision.rate}}
    end
  end

  # evaluate credit limit adjustment for an existing account
  def evaluate(%CreditAdjustmentRequest{
        account_id: account_id,
        requested_limit: new_limit,
        reason: reason,
        reviewed_by: reviewer
      })
      when new_limit > 0 do
    with {:ok, account} <- AccountStore.find(account_id),
         {:ok, bureau_report} <- CreditBureau.pull_report(account.customer_id),
         {:ok, recommendation} <-
           UnderwritingEngine.assess_credit_limit(%{
             current_limit: account.credit_limit,
             requested_limit: new_limit,
             credit_score: bureau_report.score,
             utilization: account.utilization_rate,
             payment_history: bureau_report.payment_history
           }),
         approved_limit = min(new_limit, recommendation.max_approved_limit),
         {:ok, updated} <- AccountStore.update_credit_limit(account_id, approved_limit),
         :ok <-
           RegulatoryReporter.submit_credit_decision(account.customer_id, approved_limit, reason),
         :ok <- CustomerMailer.send_credit_adjustment(account.customer_id, updated, reviewed_by) do
      Logger.info("Credit limit adjusted for account #{account_id}: #{account.credit_limit} -> #{approved_limit}")
      {:ok, %{account_id: account_id, new_limit: approved_limit}}
    end
  end

  # evaluate early repayment request and compute settlement amount
  def evaluate(%EarlyRepaymentRequest{
        loan_id: loan_id,
        repayment_date: repayment_date,
        customer_id: customer_id
      }) do
    with {:ok, loan} <- LoanStore.find(loan_id),
         :ok <- validate_loan_belongs_to_customer(loan, customer_id),
         :ok <- validate_loan_active(loan),
         {:ok, settlement} <- compute_settlement(loan, repayment_date),
         {:ok, payment} <-
           PaymentProcessor.charge(%{
             customer_id: customer_id,
             amount: settlement.total_due,
             reference: "early_repayment_#{loan_id}"
           }),
         {:ok, _} <-
           LoanStore.update(loan_id, %{
             status: :closed,
             closed_at: repayment_date,
             early_repayment_fee: settlement.early_repayment_fee
           }),
         :ok <- RegulatoryReporter.submit_loan_closure(loan_id, settlement),
         :ok <- CustomerMailer.send_repayment_confirmation(customer_id, loan, settlement) do
      Logger.info("Early repayment processed for loan #{loan_id}, payment=#{payment.id}")
      {:ok, %{settlement: settlement, payment_id: payment.id}}
    end
  end

  defp maybe_create_loan(%{status: :approved} = decision, customer_id, amount, term_months, rate) do
    LoanStore.create(%{
      customer_id: customer_id,
      principal: amount,
      term_months: term_months,
      annual_rate: rate,
      status: :active,
      disbursed_at: DateTime.utc_now()
    })
  end

  defp maybe_create_loan(%{status: :declined}, _customer_id, _amount, _term_months, _rate) do
    {:ok, nil}
  end

  defp validate_loan_belongs_to_customer(%{customer_id: id}, id), do: :ok
  defp validate_loan_belongs_to_customer(_, _), do: {:error, :loan_not_owned_by_customer}

  defp validate_loan_active(%{status: :active}), do: :ok
  defp validate_loan_active(%{status: s}), do: {:error, {:loan_not_active, s}}

  defp compute_settlement(loan, repayment_date) do
    days_remaining = Date.diff(loan.end_date, repayment_date)
    outstanding_principal = loan.principal - loan.amount_repaid
    daily_interest = outstanding_principal * loan.annual_rate / 365
    accrued_interest = daily_interest * max(0, Date.diff(repayment_date, loan.last_payment_date))
    early_repayment_fee = if days_remaining > 60, do: outstanding_principal * 0.01, else: 0

    {:ok, %{
      outstanding_principal: outstanding_principal,
      accrued_interest: round(accrued_interest),
      early_repayment_fee: round(early_repayment_fee),
      total_due: round(outstanding_principal + accrued_interest + early_repayment_fee)
    }}
  end
end
```
