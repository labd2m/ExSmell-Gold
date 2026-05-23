```elixir
defmodule Banking.AccountManager do
  @moduledoc """
  Manages bank account operations including interest calculation,
  withdrawal limit enforcement, maintenance fee application,
  and overdraft policy evaluation for different account types.
  """

  alias Banking.{Account, Transaction, Ledger, InterestEngine, FeeSchedule, OverdraftService}

  def open_account(customer_id, account_type, initial_deposit) do
    with :ok              <- validate_minimum_deposit(account_type, initial_deposit),
         {:ok, account}   <- create_account(customer_id, account_type, initial_deposit),
         {:ok, _}         <- Ledger.record_opening(account, initial_deposit) do
      {:ok, account}
    end
  end

  defp create_account(customer_id, account_type, initial_deposit) do
    account = %Account{
      customer_id:         customer_id,
      type:                account_type,
      balance:             initial_deposit,
      daily_limit:         get_daily_withdrawal_limit(account_type),
      overdraft_policy:    get_overdraft_policy(account_type),
      opened_at:           Date.utc_today()
    }

    Banking.Repo.insert(account)
  end

  def process_monthly_cycle(%Account{} = account) do
    interest   = calculate_monthly_interest(account)
    fee        = apply_maintenance_fee(account)
    net_change = interest - fee

    updated = %{account | balance: account.balance + net_change}

    with {:ok, saved} <- Banking.Repo.update(updated) do
      Ledger.record_monthly_cycle(saved, interest: interest, fee: fee)
      {:ok, saved}
    end
  end

  def withdraw(%Account{} = account, amount, today_withdrawn) do
    daily_limit = get_daily_withdrawal_limit(account.type)

    cond do
      today_withdrawn + amount > daily_limit ->
        {:error, :daily_limit_exceeded}

      account.balance - amount < 0 ->
        handle_overdraft(account, amount)

      true ->
        execute_withdrawal(account, amount)
    end
  end

  defp handle_overdraft(account, amount) do
    policy = get_overdraft_policy(account.type)
    OverdraftService.apply(account, amount, policy)
  end

  defp execute_withdrawal(account, amount) do
    updated = %{account | balance: account.balance - amount}
    with {:ok, saved} <- Banking.Repo.update(updated) do
      txn = %Transaction{account_id: saved.id, amount: -amount, type: :withdrawal}
      Ledger.record(txn)
      {:ok, saved}
    end
  end

  defp validate_minimum_deposit(:checking, amount) when amount >= 25.00, do: :ok
  defp validate_minimum_deposit(:savings, amount) when amount >= 100.00, do: :ok
  defp validate_minimum_deposit(:money_market, amount) when amount >= 1000.00, do: :ok
  defp validate_minimum_deposit(_type, _amount), do: {:error, :insufficient_opening_deposit}

  def calculate_monthly_interest(%Account{type: :checking, balance: balance}) do
    InterestEngine.compute(balance, rate: 0.001)
  end

  def calculate_monthly_interest(%Account{type: :savings, balance: balance}) do
    InterestEngine.compute(balance, rate: 0.045 / 12)
  end

  def calculate_monthly_interest(%Account{type: :money_market, balance: balance}) do
    InterestEngine.compute(balance, rate: 0.048 / 12)
  end

  def calculate_monthly_interest(%Account{balance: _balance}), do: 0.0

  def get_daily_withdrawal_limit(:checking),     do: 2_000.00
  def get_daily_withdrawal_limit(:savings),      do: 500.00
  def get_daily_withdrawal_limit(:money_market), do: 10_000.00
  def get_daily_withdrawal_limit(_),             do: 200.00

  def apply_maintenance_fee(%Account{type: :checking, balance: b}) when b >= 500, do: 0.00
  def apply_maintenance_fee(%Account{type: :checking}),                           do: 12.00
  def apply_maintenance_fee(%Account{type: :savings, balance: b}) when b >= 300,  do: 0.00
  def apply_maintenance_fee(%Account{type: :savings}),                            do: 5.00
  def apply_maintenance_fee(%Account{type: :money_market}),                       do: 0.00
  def apply_maintenance_fee(_),                                                   do: 10.00

  def get_overdraft_policy(:checking),     do: %{allowed: true,  fee: 35.00, limit: 500.00}
  def get_overdraft_policy(:savings),      do: %{allowed: false, fee: 0.00,  limit: 0.00}
  def get_overdraft_policy(:money_market), do: %{allowed: true,  fee: 25.00, limit: 1_000.00}
  def get_overdraft_policy(_),             do: %{allowed: false, fee: 0.00,  limit: 0.00}

  def close_account(%Account{balance: balance}) when balance > 0 do
    {:error, :non_zero_balance}
  end

  def close_account(%Account{} = account) do
    Banking.Repo.soft_delete(account)
  end

  def get_account_summary(%Account{} = account) do
    %{
      type:            account.type,
      balance:         account.balance,
      daily_limit:     get_daily_withdrawal_limit(account.type),
      overdraft:       get_overdraft_policy(account.type),
      opened_at:       account.opened_at
    }
  end
end
```
