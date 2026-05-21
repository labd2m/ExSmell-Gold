```elixir
defmodule Commerce.DiscountEngine do
  use GenServer

  @moduledoc """
  Applies promotional and loyalty discounts to order line items
  and totals. Supports percentage-off, fixed-amount, and tiered
  discounts as well as discount stacking and best-offer selection.

  Used during checkout finalization and cart preview.
  """

  defmodule Discount do
    @moduledoc "Represents a discount rule."
    defstruct [:id, :type, :value, :min_order, :max_discount, :label]
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end




  @doc """
  Applies a percentage discount to `total`. Returns the discounted total
  and the discount amount as `{:ok, %{total: t, discount_amount: d}}`.
  """
  def apply_percentage(pid, total, %Discount{type: :percentage} = discount) do
    GenServer.call(pid, {:apply_percentage, total, discount})
  end

  @doc """
  Applies a fixed monetary discount to `total`.
  """
  def apply_fixed(pid, total, %Discount{type: :fixed} = discount) do
    GenServer.call(pid, {:apply_fixed, total, discount})
  end

  @doc """
  Applies a tiered discount based on the order total.
  `discount.value` must be a list of `{threshold, rate}` tuples.
  """
  def apply_tiered(pid, total, %Discount{type: :tiered} = discount) do
    GenServer.call(pid, {:apply_tiered, total, discount})
  end

  @doc """
  Given multiple discount rules, returns the result of the single best
  (highest discount amount) applicable discount.
  """
  def best_of(pid, total, discounts) when is_list(discounts) do
    GenServer.call(pid, {:best_of, total, discounts})
  end

  @doc """
  Stacks a list of discounts sequentially, applying each to the result
  of the previous. Returns the final total and cumulative discount.
  """
  def stack_discounts(pid, total, discounts) when is_list(discounts) do
    GenServer.call(pid, {:stack_discounts, total, discounts})
  end
  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:apply_percentage, total, discount}, _from, state) do
    result = do_apply_percentage(total, discount)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:apply_fixed, total, discount}, _from, state) do
    result = do_apply_fixed(total, discount)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:apply_tiered, total, discount}, _from, state) do
    result = do_apply_tiered(total, discount)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:best_of, total, discounts}, _from, state) do
    results =
      discounts
      |> Enum.map(&apply_single(total, &1))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.max_by(fn {:ok, r} -> r.discount_amount end, fn -> nil end)

    reply = results || {:error, :no_applicable_discount}
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:stack_discounts, total, discounts}, _from, state) do
    {final_total, cumulative} =
      Enum.reduce(discounts, {total, 0.0}, fn discount, {current_total, acc_disc} ->
        case apply_single(current_total, discount) do
          {:ok, %{total: t, discount_amount: d}} -> {t, acc_disc + d}
          _ -> {current_total, acc_disc}
        end
      end)

    {:reply, {:ok, %{total: final_total, total_discount: Float.round(cumulative, 2)}}, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_apply_percentage(total, %Discount{value: rate, min_order: min, max_discount: cap}) do
    if is_nil(min) or total >= min do
      raw = total * rate
      amount = if cap, do: min(raw, cap), else: raw
      amount = Float.round(amount, 2)
      {:ok, %{total: Float.round(total - amount, 2), discount_amount: amount}}
    else
      {:error, :below_minimum_order}
    end
  end

  defp do_apply_fixed(total, %Discount{value: fixed, min_order: min}) do
    if is_nil(min) or total >= min do
      amount = min(fixed, total)
      {:ok, %{total: Float.round(total - amount, 2), discount_amount: Float.round(amount, 2)}}
    else
      {:error, :below_minimum_order}
    end
  end

  defp do_apply_tiered(total, %Discount{value: tiers}) do
    rate =
      tiers
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.find_value(0.0, fn {threshold, r} ->
        if total >= threshold, do: r, else: nil
      end)

    amount = Float.round(total * rate, 2)
    {:ok, %{total: Float.round(total - amount, 2), discount_amount: amount}}
  end

  defp apply_single(total, %Discount{type: :percentage} = d), do: do_apply_percentage(total, d)
  defp apply_single(total, %Discount{type: :fixed} = d), do: do_apply_fixed(total, d)
  defp apply_single(total, %Discount{type: :tiered} = d), do: do_apply_tiered(total, d)
end
```
