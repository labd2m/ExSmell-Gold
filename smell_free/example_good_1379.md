```elixir
defmodule Commerce.Returns.RefundCalculator do
  @moduledoc """
  Calculates refund amounts for order returns based on return reason,
  item condition, restocking policy, and elapsed time since purchase.
  All monetary values are integer cents.
  """

  @type return_reason :: :defective | :not_as_described | :changed_mind | :duplicate_order
  @type item_condition :: :unopened | :opened | :damaged
  @type return_item :: %{
          order_item_id: String.t(),
          quantity: pos_integer(),
          unit_price_cents: pos_integer(),
          reason: return_reason(),
          condition: item_condition()
        }

  @type refund_line :: %{
          order_item_id: String.t(),
          quantity: non_neg_integer(),
          gross_refund_cents: non_neg_integer(),
          restocking_fee_cents: non_neg_integer(),
          net_refund_cents: non_neg_integer()
        }

  @type refund_result :: %{
          lines: [refund_line()],
          total_gross_cents: non_neg_integer(),
          total_fees_cents: non_neg_integer(),
          total_net_cents: non_neg_integer()
        }

  @restocking_fee_rates %{
    changed_mind: %{unopened: 0.0, opened: 0.15, damaged: 0.40},
    duplicate_order: %{unopened: 0.0, opened: 0.05, damaged: 0.25},
    not_as_described: %{unopened: 0.0, opened: 0.0, damaged: 0.0},
    defective: %{unopened: 0.0, opened: 0.0, damaged: 0.0}
  }

  @doc """
  Computes a refund breakdown for a list of return items.
  Returns `{:ok, refund_result}` or `{:error, reason}` on invalid input.
  """
  @spec calculate([return_item()], keyword()) :: {:ok, refund_result()} | {:error, String.t()}
  def calculate(items, opts \\ []) when is_list(items) do
    days_since_purchase = Keyword.get(opts, :days_since_purchase, 0)

    with :ok <- validate_items(items),
         :ok <- validate_days(days_since_purchase) do
      lines = Enum.map(items, fn item -> compute_line(item, days_since_purchase) end)

      total_gross = Enum.reduce(lines, 0, fn l, acc -> acc + l.gross_refund_cents end)
      total_fees = Enum.reduce(lines, 0, fn l, acc -> acc + l.restocking_fee_cents end)
      total_net = Enum.reduce(lines, 0, fn l, acc -> acc + l.net_refund_cents end)

      {:ok, %{lines: lines, total_gross_cents: total_gross, total_fees_cents: total_fees, total_net_cents: total_net}}
    end
  end

  defp compute_line(item, days_since_purchase) do
    gross = item.quantity * item.unit_price_cents
    rate = restocking_rate(item.reason, item.condition)
    time_adjusted_rate = apply_time_adjustment(rate, days_since_purchase)
    fee = round(gross * time_adjusted_rate)
    net = max(gross - fee, 0)

    %{
      order_item_id: item.order_item_id,
      quantity: item.quantity,
      gross_refund_cents: gross,
      restocking_fee_cents: fee,
      net_refund_cents: net
    }
  end

  defp restocking_rate(reason, condition) do
    @restocking_fee_rates
    |> Map.get(reason, %{})
    |> Map.get(condition, 0.0)
  end

  defp apply_time_adjustment(base_rate, days) when days > 60 do
    min(base_rate + 0.10, 1.0)
  end

  defp apply_time_adjustment(base_rate, days) when days > 30 do
    min(base_rate + 0.05, 1.0)
  end

  defp apply_time_adjustment(base_rate, _days), do: base_rate

  defp validate_items([]), do: {:error, "at least one return item is required"}

  defp validate_items(items) do
    invalid = Enum.find(items, fn i -> not valid_item?(i) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid return item: #{inspect(invalid)}"}
    end
  end

  @valid_reasons ~w(defective not_as_described changed_mind duplicate_order)a
  @valid_conditions ~w(unopened opened damaged)a

  defp valid_item?(%{order_item_id: id, quantity: q, unit_price_cents: p, reason: r, condition: c})
       when is_binary(id) and id != "" and
              is_integer(q) and q > 0 and
              is_integer(p) and p > 0 and
              r in @valid_reasons and
              c in @valid_conditions,
       do: true

  defp valid_item?(_), do: false

  defp validate_days(days) when is_integer(days) and days >= 0, do: :ok
  defp validate_days(_), do: {:error, "days_since_purchase must be a non-negative integer"}
end
```
