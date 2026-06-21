```elixir
defmodule Payments.ReconciliationJob do
  @moduledoc """
  Reconciles internal payment records against a gateway statement CSV.
  For each gateway row the job looks up the internal record and classifies
  the pair as matched, missing_internally, or amount_mismatch. The result
  is a structured report suitable for finance team review. No side-effects
  are produced; only the report is returned.
  """

  @type gateway_row :: %{
          reference: String.t(),
          amount_cents: integer(),
          currency: String.t(),
          settled_on: Date.t()
        }

  @type internal_record :: %{
          reference: String.t(),
          amount_cents: integer(),
          currency: String.t()
        }

  @type match_status :: :matched | :missing_internally | :amount_mismatch | :currency_mismatch
  @type reconciliation_entry :: %{
          reference: String.t(),
          status: match_status(),
          gateway: gateway_row(),
          internal: internal_record() | nil
        }

  @type report :: %{
          total: non_neg_integer(),
          matched: non_neg_integer(),
          discrepancies: [reconciliation_entry()]
        }

  @doc """
  Reconciles `gateway_rows` against `internal_index`, a map keyed by
  payment reference. Returns a structured discrepancy report.
  """
  @spec reconcile([gateway_row()], %{String.t() => internal_record()}) :: report()
  def reconcile(gateway_rows, internal_index)
      when is_list(gateway_rows) and is_map(internal_index) do
    entries = Enum.map(gateway_rows, &classify(&1, internal_index))

    matched = Enum.count(entries, fn e -> e.status == :matched end)
    discrepancies = Enum.reject(entries, fn e -> e.status == :matched end)

    %{total: length(entries), matched: matched, discrepancies: discrepancies}
  end

  @doc "Builds an internal index map keyed by reference from a list of records."
  @spec build_index([internal_record()]) :: %{String.t() => internal_record()}
  def build_index(records) when is_list(records) do
    Map.new(records, fn r -> {r.reference, r} end)
  end

  @doc "Returns a summary string suitable for logging or email reporting."
  @spec format_summary(report()) :: String.t()
  def format_summary(%{total: total, matched: matched, discrepancies: disc}) do
    pct = if total > 0, do: Float.round(matched / total * 100, 1), else: 0.0
    "Reconciliation: #{matched}/#{total} matched (#{pct}%), #{length(disc)} discrepancy(ies)"
  end

  defp classify(%{reference: ref} = gw_row, internal_index) do
    case Map.get(internal_index, ref) do
      nil ->
        %{reference: ref, status: :missing_internally, gateway: gw_row, internal: nil}

      %{currency: ic} = internal when ic != gw_row.currency ->
        %{reference: ref, status: :currency_mismatch, gateway: gw_row, internal: internal}

      %{amount_cents: ia} = internal when ia != gw_row.amount_cents ->
        %{reference: ref, status: :amount_mismatch, gateway: gw_row, internal: internal}

      internal ->
        %{reference: ref, status: :matched, gateway: gw_row, internal: internal}
    end
  end
end
```
