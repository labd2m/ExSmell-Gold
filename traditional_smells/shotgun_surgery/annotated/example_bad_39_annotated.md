## Smell Metadata

- **Smell:** Shotgun Surgery
- **Expected Smell Location:** Functions `monthly_fee/1`, `interest_rate/1`, `overdraft_limit/1` in `Banking.AccountPolicy`; `transaction_limit_daily/1`, `requires_2fa?/1` in `Banking.TransactionGuard`; `kyc_tier/1`, `report_threshold/1` in `Banking.ComplianceChecker`
- **Affected Functions:** See above (6 functions across 3 modules)
- **Explanation:** Adding a new bank account type (e.g., `:premium`) requires scattered changes across three separate banking modules. Fee structures, transaction limits, and compliance tiers are each independently pattern-matched per account type with no centralized account type configuration.

```elixir
defmodule Banking.AccountPolicy do
  @moduledoc """
  Defines the fee structures, interest rates, and credit facilities
  available to each bank account type offered on the platform.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: This is a smell because adding a new account type (e.g., :premium)
  # VALIDATION: requires new clauses in monthly_fee/1, interest_rate/1, and
  # VALIDATION: overdraft_limit/1 here, AND independent changes in
  # VALIDATION: Banking.TransactionGuard and Banking.ComplianceChecker.

  @spec monthly_fee(atom()) :: float()
  def monthly_fee(:basic),    do: 0.0
  def monthly_fee(:standard), do: 5.0
  def monthly_fee(:business), do: 25.0

  @spec interest_rate(atom()) :: float()
  def interest_rate(:basic),    do: 0.001
  def interest_rate(:standard), do: 0.015
  def interest_rate(:business), do: 0.005

  @spec overdraft_limit(atom()) :: float()
  def overdraft_limit(:basic),    do: 0.0
  def overdraft_limit(:standard), do: 500.0
  def overdraft_limit(:business), do: 5_000.0

  # VALIDATION: SMELL END

  def apply_monthly_charges(account) do
    fee = monthly_fee(account.type)

    if fee > 0.0 do
      {:ok, %{deducted: fee, new_balance: account.balance - fee}}
    else
      {:ok, %{deducted: 0.0, new_balance: account.balance}}
    end
  end

  def accrue_interest(account) do
    rate   = interest_rate(account.type)
    earned = account.balance * rate / 12

    {:ok, %{earned: Float.round(earned, 4), new_balance: account.balance + earned}}
  end

  def available_balance(account) do
    account.balance + overdraft_limit(account.type)
  end
end

defmodule Banking.TransactionGuard do
  @moduledoc """
  Enforces per-account-type daily transaction limits and step-up
  authentication requirements to protect against fraud and abuse.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: transaction_limit_daily/1 and requires_2fa?/1 require independent
  # VALIDATION: new clauses per account type, separate from AccountPolicy and
  # VALIDATION: ComplianceChecker.

  @spec transaction_limit_daily(atom()) :: float()
  def transaction_limit_daily(:basic),    do: 500.0
  def transaction_limit_daily(:standard), do: 2_000.0
  def transaction_limit_daily(:business), do: 50_000.0

  @spec requires_2fa?(atom()) :: boolean()
  def requires_2fa?(:basic),    do: false
  def requires_2fa?(:standard), do: true
  def requires_2fa?(:business), do: true

  # VALIDATION: SMELL END

  def authorize_transaction(account, transaction) do
    limit  = transaction_limit_daily(account.type)
    used   = daily_spent(account.id)
    remaining = limit - used

    cond do
      transaction.amount > remaining ->
        {:error, {:limit_exceeded, %{available: remaining, requested: transaction.amount}}}

      requires_2fa?(account.type) and not transaction.mfa_verified? ->
        {:error, :mfa_required}

      true ->
        :ok
    end
  end

  defp daily_spent(_account_id), do: 0.0
end

defmodule Banking.ComplianceChecker do
  @moduledoc """
  Applies anti-money-laundering KYC tier requirements and automated
  transaction reporting thresholds for each account classification.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: kyc_tier/1 and report_threshold/1 must also be independently updated
  # VALIDATION: for each new account type, adding another disconnected change point.

  @spec kyc_tier(atom()) :: atom()
  def kyc_tier(:basic),    do: :simplified
  def kyc_tier(:standard), do: :standard
  def kyc_tier(:business), do: :enhanced

  @spec report_threshold(atom()) :: float()
  def report_threshold(:basic),    do: 10_000.0
  def report_threshold(:standard), do: 10_000.0
  def report_threshold(:business), do: 25_000.0

  # VALIDATION: SMELL END

  def validate_kyc(account, customer) do
    required_tier = kyc_tier(account.type)
    verified_tier = customer.kyc_tier

    if tier_sufficient?(verified_tier, required_tier) do
      :ok
    else
      {:error, {:kyc_upgrade_required, %{have: verified_tier, need: required_tier}}}
    end
  end

  def check_report_obligation(account, transaction) do
    threshold = report_threshold(account.type)

    if transaction.amount >= threshold do
      {:report, %{
        account_id:     account.id,
        customer_id:    account.customer_id,
        amount:         transaction.amount,
        transaction_id: transaction.id,
        reported_at:    DateTime.utc_now()
      }}
    else
      :ok
    end
  end

  defp tier_sufficient?(:enhanced, _),             do: true
  defp tier_sufficient?(:standard, :enhanced),     do: false
  defp tier_sufficient?(:standard, _),             do: true
  defp tier_sufficient?(:simplified, :simplified), do: true
  defp tier_sufficient?(_, _),                     do: false
end
```
