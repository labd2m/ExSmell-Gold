```elixir
defmodule Payments.Reconciliation.StatementMatcher do
  @moduledoc """
  Matches incoming bank statement entries against recorded payment transactions.

  Produces reconciliation reports identifying matched, unmatched, and
  disputed entries within a given settlement window.
  """

  alias Payments.Reconciliation.{StatementEntry, PaymentRecord, ReconciliationReport}
  alias Payments.Repo
  import Ecto.Query, warn: false

  @type match_result ::
          {:matched, StatementEntry.t(), PaymentRecord.t()}
          | {:unmatched_entry, StatementEntry.t()}
          | {:unmatched_payment, PaymentRecord.t()}

  @type reconciliation_opts :: [
          tolerance: Decimal.t(),
          date_window_days: pos_integer()
        ]

  @doc """
  Reconciles a list of bank statement entries against recorded payments
  within the given date window.

  Returns a structured report grouping matched, unmatched, and disputed records.
  """
  @spec reconcile([StatementEntry.t()], Date.t(), Date.t(), reconciliation_opts()) ::
          {:ok, ReconciliationReport.t()} | {:error, :invalid_date_range}
  def reconcile(entries, from_date, to_date, opts \\ []) do
    if Date.compare(from_date, to_date) == :gt do
      {:error, :invalid_date_range}
    else
      tolerance = Keyword.get(opts, :tolerance, Decimal.new("0.01"))
      date_window = Keyword.get(opts, :date_window_days, 3)

      payments = load_payments(from_date, to_date)
      results = match_entries(entries, payments, tolerance, date_window)
      report = build_report(results, from_date, to_date)

      {:ok, report}
    end
  end

  defp load_payments(from_date, to_date) do
    PaymentRecord
    |> where([p], p.settlement_date >= ^from_date and p.settlement_date <= ^to_date)
    |> where([p], p.status == :settled)
    |> Repo.all()
  end

  defp match_entries(entries, payments, tolerance, date_window) do
    {results, remaining_payments} =
      Enum.reduce(entries, {[], payments}, fn entry, {acc, unmatched_payments} ->
        case find_match(entry, unmatched_payments, tolerance, date_window) do
          {:ok, payment, rest} ->
            {[{:matched, entry, payment} | acc], rest}

          :no_match ->
            {[{:unmatched_entry, entry} | acc], unmatched_payments}
        end
      end)

    leftover = Enum.map(remaining_payments, &{:unmatched_payment, &1})
    results ++ leftover
  end

  defp find_match(entry, payments, tolerance, date_window) do
    match =
      Enum.find(payments, fn payment ->
        amounts_match?(entry.amount, payment.amount, tolerance) and
          dates_within_window?(entry.value_date, payment.settlement_date, date_window)
      end)

    case match do
      nil -> :no_match
      payment -> {:ok, payment, List.delete(payments, payment)}
    end
  end

  defp amounts_match?(entry_amount, payment_amount, tolerance) do
    diff = entry_amount |> Decimal.sub(payment_amount) |> Decimal.abs()
    Decimal.compare(diff, tolerance) in [:lt, :eq]
  end

  defp dates_within_window?(entry_date, payment_date, window_days) do
    diff = Date.diff(entry_date, payment_date) |> abs()
    diff <= window_days
  end

  defp build_report(results, from_date, to_date) do
    grouped = Enum.group_by(results, fn {tag, _, _} -> tag end,
                fn
                  {_, a, b} when not is_nil(b) -> {a, b}
                  {_, a} -> a
                end)

    %ReconciliationReport{
      from_date: from_date,
      to_date: to_date,
      matched: Map.get(grouped, :matched, []),
      unmatched_entries: Map.get(grouped, :unmatched_entry, []),
      unmatched_payments: Map.get(grouped, :unmatched_payment, []),
      generated_at: DateTime.utc_now()
    }
  end
end
```
