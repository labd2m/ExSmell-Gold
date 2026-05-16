# Example 46: Multi-Currency FX Conversion Service - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `Finance.FxConverter.convert/4` function
- **Affected Functions**: `convert/4`
- **Explanation**: The function does not validate that `amount` is a number before multiplying it against the retrieved exchange rate. A binary or atom passed as `amount` will raise an ArithmeticError deep inside the multiplication expression rather than at the public function boundary.

## Code

```elixir
defmodule Finance.FxConverter do
  @moduledoc """
  Performs real-time and historical currency conversions, manages exchange
  rate snapshots, and produces FX gain/loss reports for treasury operations.
  """

  alias Finance.{ExchangeRate, ConversionRecord, RateSnapshot, TreasuryAccount, AuditLog}

  @supported_currencies ~w(USD EUR GBP JPY CHF AUD CAD SGD HKD NOK SEK DKK)
  @rate_staleness_threshold_seconds 300

  def fetch_live_rate(from_currency, to_currency) do
    with :ok <- validate_currency_pair(from_currency, to_currency),
         {:ok, rate} <- ExchangeRate.fetch_live(from_currency, to_currency),
         :ok <- validate_rate_freshness(rate) do

      {:ok, %{
        from: from_currency,
        to: to_currency,
        rate: rate.value,
        inverse_rate: 1.0 / rate.value,
        fetched_at: rate.fetched_at,
        source: rate.source
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `amount` is not validated to be a numeric
  # VALIDATION: value before it is multiplied against `rate.value`. If a caller
  # VALIDATION: passes a string (e.g., "1500.00") or an atom, the ArithmeticError
  # VALIDATION: will surface inside `converted_amount = amount * rate.value` rather
  # VALIDATION: than at the boundary of this public function, making debugging difficult.
  def convert(amount, from_currency, to_currency, opts \\ []) do
    as_of = Keyword.get(opts, :as_of, :live)
    account_id = Keyword.get(opts, :account_id)

    with :ok <- validate_currency_pair(from_currency, to_currency),
         {:ok, rate} <- get_rate(from_currency, to_currency, as_of) do

      # No type validation on amount before arithmetic
      converted_amount = amount * rate.value
      fee = compute_conversion_fee(amount, from_currency, account_id)
      net_converted = converted_amount - fee * rate.value

      record = %ConversionRecord{
        id: generate_conversion_id(),
        from_currency: from_currency,
        to_currency: to_currency,
        original_amount: amount,
        converted_amount: Float.round(converted_amount, 4),
        exchange_rate: rate.value,
        fee_in_from_currency: Float.round(fee, 4),
        net_converted_amount: Float.round(net_converted, 4),
        account_id: account_id,
        rate_as_of: rate.fetched_at,
        converted_at: DateTime.utc_now()
      }

      {:ok, _} = ConversionRecord.insert(record)

      if account_id do
        {:ok, _} = AuditLog.record(:fx_conversion, account_id, %{record_id: record.id})
      end

      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def convert_batch(conversions, opts \\ []) do
    results =
      Enum.map(conversions, fn %{amount: a, from: f, to: t} ->
        case convert(a, f, t, opts) do
          {:ok, record} -> {:ok, record}
          {:error, reason} -> {:error, %{from: f, to: t, amount: a, reason: reason}}
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    failures = Enum.filter(results, &match?({:error, _}, &1))

    {:ok, %{
      total: length(results),
      succeeded: length(successes),
      failed: length(failures),
      records: Enum.map(successes, fn {:ok, r} -> r end),
      errors: Enum.map(failures, fn {:error, e} -> e end)
    }}
  end

  def snapshot_rates(currency_pairs) do
    rates =
      Enum.map(currency_pairs, fn {from, to} ->
        case ExchangeRate.fetch_live(from, to) do
          {:ok, rate} -> {:ok, {from, to, rate.value, rate.fetched_at}}
          {:error, reason} -> {:error, {from, to, reason}}
        end
      end)

    successful = Enum.filter(rates, &match?({:ok, _}, &1))

    snapshot = %RateSnapshot{
      id: generate_snapshot_id(),
      rates: Enum.map(successful, fn {:ok, {f, t, v, at}} -> %{from: f, to: t, rate: v, as_of: at} end),
      captured_at: DateTime.utc_now()
    }

    {:ok, _} = RateSnapshot.insert(snapshot)
    {:ok, snapshot}
  end

  def fx_gain_loss_report(account_id, start_date, end_date, base_currency) do
    with {:ok, account} <- TreasuryAccount.get(account_id),
         {:ok, records} <- ConversionRecord.list_for_account_in_range(account_id, start_date, end_date) do

      gain_loss_by_currency =
        records
        |> Enum.group_by(& &1.from_currency)
        |> Enum.map(fn {currency, recs} ->
          total_original = Enum.sum(Enum.map(recs, & &1.original_amount))
          total_converted = Enum.sum(Enum.map(recs, & &1.converted_amount))

          {:ok, current_rate} = get_rate(currency, base_currency, :live)
          current_value = total_original * current_rate.value
          book_value = total_converted

          gain_loss = current_value - book_value
          {currency, %{total_original: total_original, book_value: Float.round(book_value, 2), current_value: Float.round(current_value, 2), gain_loss: Float.round(gain_loss, 2)}}
        end)
        |> Map.new()

      total_gain_loss = gain_loss_by_currency |> Map.values() |> Enum.sum_by(& &1.gain_loss)

      {:ok, %{
        account_id: account_id,
        period: %{start: start_date, end: end_date},
        base_currency: base_currency,
        by_currency: gain_loss_by_currency,
        total_gain_loss: Float.round(total_gain_loss, 2),
        generated_at: DateTime.utc_now()
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def get_historical_rate(from_currency, to_currency, date) do
    with :ok <- validate_currency_pair(from_currency, to_currency) do
      case RateSnapshot.find_for_date(from_currency, to_currency, date) do
        {:ok, snapshot_rate} ->
          {:ok, %{from: from_currency, to: to_currency, rate: snapshot_rate.rate, as_of: snapshot_rate.as_of}}

        {:error, :not_found} ->
          {:error, :historical_rate_unavailable}

        error ->
          error
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_rate(from, to, :live) do
    with {:ok, rate} <- ExchangeRate.fetch_live(from, to),
         :ok <- validate_rate_freshness(rate) do
      {:ok, rate}
    end
  end

  defp get_rate(from, to, %Date{} = as_of) do
    case RateSnapshot.find_for_date(from, to, as_of) do
      {:ok, r} -> {:ok, r}
      {:error, _} -> {:error, :historical_rate_unavailable}
    end
  end

  defp compute_conversion_fee(_amount, _currency, nil), do: 0.0
  defp compute_conversion_fee(amount, _currency, _account_id) do
    amount * 0.005
  end

  defp validate_currency_pair(from, to) do
    cond do
      from not in @supported_currencies -> {:error, {:unsupported_currency, from}}
      to not in @supported_currencies -> {:error, {:unsupported_currency, to}}
      from == to -> {:error, :same_currency_conversion}
      true -> :ok
    end
  end

  defp validate_rate_freshness(%{fetched_at: fetched_at}) do
    age = DateTime.diff(DateTime.utc_now(), fetched_at, :second)
    if age <= @rate_staleness_threshold_seconds, do: :ok, else: {:error, :stale_rate}
  end

  defp generate_conversion_id, do: "fx_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  defp generate_snapshot_id, do: "snap_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
end
```
