```elixir
defmodule Payments.SplitChargeCalculator do
  @moduledoc """
  Calculates how a total payment amount should be split across multiple
  payment instruments. Supports primary + backup card ordering, wallet
  balance partial payments, and gift card redemption before charging a
  card. All arithmetic uses integer cents to prevent rounding drift.
  """

  @type instrument_type :: :wallet | :gift_card | :card
  @type instrument :: %{
          id: String.t(),
          type: instrument_type(),
          available_cents: pos_integer(),
          priority: pos_integer()
        }
  @type charge :: %{
          instrument_id: String.t(),
          instrument_type: instrument_type(),
          amount_cents: pos_integer()
        }
  @type split_result :: %{charges: [charge()], total_cents: pos_integer()}

  @doc """
  Splits `total_cents` across `instruments` sorted by priority ascending.
  Lower-priority-number instruments are charged first. Returns the
  ordered list of per-instrument charges needed to cover the total.
  Returns `{:error, :insufficient_funds}` when the combined available
  balance is less than the total.
  """
  @spec split(pos_integer(), [instrument()]) ::
          {:ok, split_result()} | {:error, :insufficient_funds}
  def split(total_cents, instruments)
      when is_integer(total_cents) and total_cents > 0 and is_list(instruments) do
    sorted = Enum.sort_by(instruments, & &1.priority)
    available = Enum.sum_by(sorted, & &1.available_cents)

    if available < total_cents do
      {:error, :insufficient_funds}
    else
      {charges, _remaining} =
        Enum.reduce_while(sorted, {[], total_cents}, fn instrument, {acc, remaining} ->
          if remaining == 0 do
            {:halt, {acc, 0}}
          else
            take = min(instrument.available_cents, remaining)
            charge = %{
              instrument_id: instrument.id,
              instrument_type: instrument.type,
              amount_cents: take
            }
            {:cont, {[charge | acc], remaining - take}}
          end
        end)

      {:ok, %{charges: Enum.reverse(charges), total_cents: total_cents}}
    end
  end

  @doc "Returns the charge for a specific instrument ID from the result, or nil."
  @spec charge_for(split_result(), String.t()) :: charge() | nil
  def charge_for(%{charges: charges}, instrument_id) when is_binary(instrument_id) do
    Enum.find(charges, fn c -> c.instrument_id == instrument_id end)
  end

  @doc "Returns the total cents allocated to instruments of the given `type`."
  @spec total_by_type(split_result(), instrument_type()) :: non_neg_integer()
  def total_by_type(%{charges: charges}, type) when is_atom(type) do
    charges
    |> Enum.filter(fn c -> c.instrument_type == type end)
    |> Enum.sum_by(& &1.amount_cents)
  end

  @doc "Returns a human-readable summary string for a split result."
  @spec describe(split_result()) :: String.t()
  def describe(%{charges: charges, total_cents: total}) do
    lines = Enum.map(charges, fn c ->
      dollars = c.amount_cents / 100
      "  #{c.instrument_type} #{c.instrument_id}: $#{:erlang.float_to_binary(dollars, decimals: 2)}"
    end)

    total_str = :erlang.float_to_binary(total / 100, decimals: 2)
    (["Total: $#{total_str}"] ++ lines) |> Enum.join("\\n")
  end
end
```
