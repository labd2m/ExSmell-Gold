# Example 43: Loan Origination and Amortization Service - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `Lending.LoanOriginator.calculate_amortization_schedule/4` function
- **Affected Functions**: `calculate_amortization_schedule/4`
- **Explanation**: The function does not validate that `principal`, `annual_rate`, and `term_months` are numeric before passing them into the amortization formula. If a caller passes a string for any of these (e.g., "50000" or "5.5"), the error will surface inside the mathematical expressions rather than at the public boundary.

## Code

```elixir
defmodule Lending.LoanOriginator do
  @moduledoc """
  Handles loan applications, credit decisioning, amortization schedule
  generation, and disbursement workflows for the retail lending platform.
  """

  alias Lending.{Applicant, LoanApplication, LoanAccount, AmortizationSchedule,
                  CreditBureau, Disbursement, AuditLog}

  @max_dti_ratio 0.43
  @min_credit_score 620
  @origination_fee_rate 0.01

  def submit_application(applicant_id, loan_params) do
    with {:ok, applicant} <- Applicant.get(applicant_id),
         :ok <- validate_loan_params(loan_params),
         {:ok, credit_report} <- CreditBureau.pull_report(applicant.ssn),
         :ok <- validate_credit_score(credit_report),
         {:ok, dti} <- compute_dti(applicant, loan_params.requested_amount) do

      decision = make_credit_decision(credit_report, dti, loan_params)

      application = %LoanApplication{
        id: generate_application_id(),
        applicant_id: applicant_id,
        requested_amount: loan_params.requested_amount,
        requested_term_months: loan_params.term_months,
        loan_purpose: loan_params.purpose,
        credit_score: credit_report.score,
        dti_ratio: dti,
        decision: decision,
        submitted_at: DateTime.utc_now()
      }

      {:ok, _} = LoanApplication.insert(application)
      {:ok, _} = AuditLog.record(:application_submitted, applicant_id, %{application_id: application.id})

      {:ok, application}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `principal`, `annual_rate`, and
  # VALIDATION: `term_months` are used directly in arithmetic expressions and
  # VALIDATION: the `:math.pow/2` call without any type validation at the boundary.
  # VALIDATION: Passing a binary like "50000" or an atom like :standard_rate will
  # VALIDATION: cause a confusing ArithmeticError or BadArg deep inside the
  # VALIDATION: amortization formula rather than a clear error at the function entry.
  def calculate_amortization_schedule(application_id, principal, annual_rate, term_months) do
    with {:ok, application} <- LoanApplication.get(application_id),
         :ok <- validate_application_approved(application) do

      # No type validation on principal, annual_rate, or term_months
      monthly_rate = annual_rate / 12 / 100

      monthly_payment =
        if monthly_rate == 0 do
          principal / term_months
        else
          principal * monthly_rate * :math.pow(1 + monthly_rate, term_months) /
            (:math.pow(1 + monthly_rate, term_months) - 1)
        end

      origination_fee = principal * @origination_fee_rate

      {schedule, _} =
        Enum.map_reduce(1..term_months, principal, fn period, balance ->
          interest_charge = balance * monthly_rate
          principal_charge = monthly_payment - interest_charge
          ending_balance = max(0, balance - principal_charge)

          entry = %{
            period: period,
            beginning_balance: Float.round(balance, 2),
            payment: Float.round(monthly_payment, 2),
            principal: Float.round(principal_charge, 2),
            interest: Float.round(interest_charge, 2),
            ending_balance: Float.round(ending_balance, 2)
          }

          {entry, ending_balance}
        end)

      total_interest = Enum.sum(Enum.map(schedule, & &1.interest))
      total_paid = monthly_payment * term_months

      amort = %AmortizationSchedule{
        id: generate_schedule_id(),
        application_id: application_id,
        principal: principal,
        annual_rate: annual_rate,
        term_months: term_months,
        monthly_payment: Float.round(monthly_payment, 2),
        origination_fee: Float.round(origination_fee, 2),
        total_interest: Float.round(total_interest, 2),
        total_cost: Float.round(total_paid + origination_fee, 2),
        schedule: schedule,
        generated_at: DateTime.utc_now()
      }

      {:ok, _} = AmortizationSchedule.insert(amort)
      {:ok, amort}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def approve_and_disburse(application_id, approved_amount, approved_rate, approved_term) do
    with {:ok, application} <- LoanApplication.get(application_id),
         :ok <- validate_application_approved(application),
         {:ok, applicant} <- Applicant.get(application.applicant_id),
         {:ok, amort} <- calculate_amortization_schedule(application_id, approved_amount, approved_rate, approved_term) do

      account = %LoanAccount{
        id: generate_account_id(),
        application_id: application_id,
        applicant_id: application.applicant_id,
        principal: approved_amount,
        outstanding_balance: approved_amount,
        annual_rate: approved_rate,
        term_months: approved_term,
        monthly_payment: amort.monthly_payment,
        schedule_id: amort.id,
        status: :active,
        disbursed_at: DateTime.utc_now(),
        next_payment_due: first_payment_date()
      }

      {:ok, _} = LoanAccount.insert(account)

      disbursement = %Disbursement{
        id: generate_disbursement_id(),
        account_id: account.id,
        amount: approved_amount,
        method: :ach,
        status: :pending,
        initiated_at: DateTime.utc_now()
      }

      {:ok, _} = Disbursement.insert(disbursement)
      {:ok, _} = LoanApplication.update(application_id, %{status: :disbursed, account_id: account.id})
      {:ok, _} = AuditLog.record(:loan_disbursed, applicant.id, %{account_id: account.id, amount: approved_amount})

      {:ok, %{account: account, disbursement: disbursement, schedule: amort}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def record_payment(account_id, payment_amount, payment_date) do
    with {:ok, account} <- LoanAccount.get(account_id),
         :ok <- validate_account_active(account) do

      interest_portion = account.outstanding_balance * account.annual_rate / 12 / 100
      principal_portion = payment_amount - interest_portion
      new_balance = max(0, account.outstanding_balance - principal_portion)

      payment = %{
        account_id: account_id,
        amount: payment_amount,
        principal_applied: Float.round(principal_portion, 2),
        interest_applied: Float.round(interest_portion, 2),
        balance_after: Float.round(new_balance, 2),
        payment_date: payment_date,
        recorded_at: DateTime.utc_now()
      }

      {:ok, _} = LoanAccount.record_payment(payment)
      {:ok, _} = LoanAccount.update(account_id, %{outstanding_balance: new_balance})

      if new_balance == 0 do
        {:ok, _} = LoanAccount.update(account_id, %{status: :paid_off, paid_off_at: DateTime.utc_now()})
      end

      {:ok, payment}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_delinquent_accounts(days_past_due \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days_past_due)

    with {:ok, accounts} <- LoanAccount.list_with_payment_due_before(cutoff) do
      delinquent =
        Enum.filter(accounts, fn a -> a.status == :active and a.last_payment_date < cutoff end)
        |> Enum.map(fn a ->
          %{
            account_id: a.id,
            applicant_id: a.applicant_id,
            outstanding_balance: a.outstanding_balance,
            days_past_due: Date.diff(Date.utc_today(), a.next_payment_due),
            last_payment: a.last_payment_date
          }
        end)

      {:ok, delinquent}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp compute_dti(applicant, loan_amount) do
    estimated_payment = loan_amount * 0.02
    total_monthly_debt = applicant.existing_monthly_debt + estimated_payment
    dti = total_monthly_debt / applicant.gross_monthly_income
    {:ok, Float.round(dti, 4)}
  end

  defp make_credit_decision(credit_report, dti, loan_params) do
    cond do
      credit_report.score < @min_credit_score -> :declined
      dti > @max_dti_ratio -> :declined
      loan_params.requested_amount > max_loan_for_score(credit_report.score) -> :declined
      true -> :approved
    end
  end

  defp max_loan_for_score(score) when score >= 750, do: 100_000
  defp max_loan_for_score(score) when score >= 700, do: 75_000
  defp max_loan_for_score(score) when score >= 660, do: 50_000
  defp max_loan_for_score(_), do: 25_000

  defp validate_loan_params(params) do
    cond do
      params.requested_amount <= 0 -> {:error, :invalid_amount}
      params.term_months not in [12, 24, 36, 48, 60, 72, 84] -> {:error, :invalid_term}
      true -> :ok
    end
  end

  defp validate_credit_score(%{score: score}) when score >= @min_credit_score, do: :ok
  defp validate_credit_score(_), do: {:error, :credit_score_too_low}

  defp validate_application_approved(%{decision: :approved}), do: :ok
  defp validate_application_approved(_), do: {:error, :application_not_approved}

  defp validate_account_active(%{status: :active}), do: :ok
  defp validate_account_active(_), do: {:error, :account_not_active}

  defp first_payment_date do
    today = Date.utc_today()
    Date.add(today, 30)
  end

  defp generate_application_id, do: "app_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  defp generate_schedule_id, do: "sch_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  defp generate_account_id, do: "acct_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  defp generate_disbursement_id, do: "disb_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
end
```
