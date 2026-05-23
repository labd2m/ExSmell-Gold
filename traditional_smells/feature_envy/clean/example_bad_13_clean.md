```elixir
defmodule Reports.FinancialReport do
  @moduledoc """
  Generates financial reports and summaries for internal and external stakeholders.
  """

  alias Reports.{Account, Transaction, Period, ExportFormatter, ChartBuilder}
  require Logger

  @default_decimal_places 2

  def generate_period_report(period_id, account_ids) do
    period = Period.fetch!(period_id)
    accounts = Enum.map(account_ids, &Account.fetch!/1)
    transactions = Transaction.list_for_period(period.start_date, period.end_date, account_ids)
    summary = build_summary(transactions, period)
    ExportFormatter.to_pdf(summary, accounts, period)
  end

  def build_chart_data(account_ids, period_id) do
    period = Period.fetch!(period_id)
    transactions = Transaction.list_for_period(period.start_date, period.end_date, account_ids)
    ChartBuilder.build(transactions, period)
  end

  def export_csv(account_ids, period_id) do
    period = Period.fetch!(period_id)
    transactions = Transaction.list_for_period(period.start_date, period.end_date, account_ids)
    ExportFormatter.to_csv(transactions)
  end

  def list_accounts_by_type(type) do
    Account.list_by_type(type)
  end

  def reconciliation_status(account_ids) do
    account_ids
    |> Enum.map(&Account.fetch!/1)
    |> Enum.map(fn acc -> {acc.id, acc.is_reconciled} end)
    |> Map.new()
  end

  def compile_account_snapshot(account_id) do
    account = Account.fetch!(account_id)

    ledger_balance = Account.ledger_balance(account)
    pending = Account.pending_transactions(account)
    pending_total = Enum.reduce(pending, Decimal.new(0), &Decimal.add(&1.amount, &2))
    available_balance = Decimal.sub(ledger_balance, pending_total)

    credit_facilities = Account.credit_facilities(account)
    credit_used = Enum.reduce(credit_facilities, Decimal.new(0), &Decimal.add(&1.drawn, &2))
    credit_available = Enum.reduce(credit_facilities, Decimal.new(0), &Decimal.add(&1.limit, &2))

    liabilities = Account.liability_total(account)
    assets = Account.asset_total(account)
    net_position = Decimal.sub(assets, liabilities)

    cost_center = Account.cost_center(account)
    owner = Account.owner_info(account)

    %{
      account_code: account.code,
      account_name: account.name,
      account_type: account.type,
      currency: account.currency,
      is_reconciled: account.is_reconciled,
      ledger_balance: ledger_balance,
      pending_transaction_total: pending_total,
      available_balance: available_balance,
      credit_used: credit_used,
      credit_available: credit_available,
      total_assets: assets,
      total_liabilities: liabilities,
      net_position: net_position,
      cost_center: cost_center,
      owner: owner,
      snapshot_at: DateTime.utc_now()
    }
  end

  defp build_summary(transactions, period) do
    total_credits =
      transactions
      |> Enum.filter(&(&1.type == :credit))
      |> Enum.reduce(0, &(&1.amount + &2))

    total_debits =
      transactions
      |> Enum.filter(&(&1.type == :debit))
      |> Enum.reduce(0, &(&1.amount + &2))

    %{
      period: period,
      total_credits: total_credits,
      total_debits: total_debits,
      net: total_credits - total_debits
    }
  end
end
```
