```elixir
defmodule Banking.LedgerSummary do
  @moduledoc """
  Computes summary statistics over a set of ledger entries for account
  statement generation and regulatory balance reporting.

  Ledger entries are plain maps with at least `:type` (`:credit` or `:debit`),
  `:amount_cents` (integer), and `:posted_at` (DateTime) fields.
  """

  @doc """
  Computes a complete summary over a list of ledger entries.

  Returns a map containing:
    - `:total_credits` — total credited amount in cents
    - `:total_debits` — total debited amount in cents
    - `:net_balance` — credits minus debits in cents
    - `:entry_count` — total number of entries
    - `:period_start` — earliest posted date (or `nil`)
    - `:period_end` — latest posted date (or `nil`)
  """
  def summarize_entries(entries) do
    Enum.reduce(entries, initial_accumulator(), fn entry, acc ->
      acc
      |> accumulate_amount(entry)
      |> accumulate_dates(entry)
      |> Map.update!(:entry_count, &(&1 + 1))
    end)
    |> finalize_summary()
  end

  @doc """
  Filters entries to only those within a given date range.
  """
  def entries_in_range(entries, %Date{} = from, %Date{} = to)
      when is_list(entries) do
    Enum.filter(entries, fn entry ->
      entry_date = DateTime.to_date(entry.posted_at)
      Date.compare(entry_date, from) != :lt and
        Date.compare(entry_date, to) != :gt
    end)
  end

  @doc """
  Groups ledger entries by calendar month.
  """
  def group_by_month(entries) when is_list(entries) do
    Enum.group_by(entries, fn entry ->
      dt = entry.posted_at
      {dt.year, dt.month}
    end)
  end

  @doc """
  Returns the running balance after each entry, sorted by posted date.
  """
  def running_balance(entries, opening_balance_cents \\ 0)
      when is_list(entries) and is_integer(opening_balance_cents) do
    sorted = Enum.sort_by(entries, & &1.posted_at, {:asc, DateTime})

    {_final, pairs} =
      Enum.map_reduce(sorted, opening_balance_cents, fn entry, balance ->
        delta = entry_delta(entry)
        new_balance = balance + delta
        {Map.put(entry, :running_balance, new_balance), new_balance}
      end)

    pairs
  end

  @doc """
  Returns the net delta (positive for credit, negative for debit) of an entry.
  """
  def entry_delta(%{type: :credit, amount_cents: amount}) when is_integer(amount), do: amount
  def entry_delta(%{type: :debit, amount_cents: amount}) when is_integer(amount), do: -amount

  # --- Private ---

  defp initial_accumulator do
    %{
      total_credits: 0,
      total_debits: 0,
      net_balance: 0,
      entry_count: 0,
      period_start: nil,
      period_end: nil
    }
  end

  defp accumulate_amount(acc, %{type: :credit, amount_cents: amount}) when is_integer(amount) do
    Map.update!(acc, :total_credits, &(&1 + amount))
  end

  defp accumulate_amount(acc, %{type: :debit, amount_cents: amount}) when is_integer(amount) do
    Map.update!(acc, :total_debits, &(&1 + amount))
  end

  defp accumulate_amount(acc, _entry), do: acc

  defp accumulate_dates(acc, %{posted_at: %DateTime{} = dt}) do
    acc
    |> update_period_start(dt)
    |> update_period_end(dt)
  end

  defp accumulate_dates(acc, _), do: acc

  defp update_period_start(%{period_start: nil} = acc, dt), do: %{acc | period_start: dt}
  defp update_period_start(acc, dt) do
    if DateTime.compare(dt, acc.period_start) == :lt, do: %{acc | period_start: dt}, else: acc
  end

  defp update_period_end(%{period_end: nil} = acc, dt), do: %{acc | period_end: dt}
  defp update_period_end(acc, dt) do
    if DateTime.compare(dt, acc.period_end) == :gt, do: %{acc | period_end: dt}, else: acc
  end

  defp finalize_summary(acc) do
    %{acc | net_balance: acc.total_credits - acc.total_debits}
  end
end
```
