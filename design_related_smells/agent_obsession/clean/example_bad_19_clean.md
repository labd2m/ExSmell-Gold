```elixir
defmodule BillingCart do
  @moduledoc """
  Manages shopping cart state for a billing session.
  """

  def new do
    {:ok, pid} = Agent.start_link(fn -> %{items: [], total: 0.0, discounts: [], tax_rate: 0.0} end)
    pid
  end

  def add_item(pid, item) do
    Agent.update(pid, fn state ->
      updated_items = [item | state.items]
      new_total = Enum.reduce(updated_items, 0.0, fn i, acc -> acc + i.price * i.qty end)
      %{state | items: updated_items, total: new_total}
    end)
  end

  def remove_item(pid, item_id) do
    Agent.update(pid, fn state ->
      updated_items = Enum.reject(state.items, fn i -> i.id == item_id end)
      new_total = Enum.reduce(updated_items, 0.0, fn i, acc -> acc + i.price * i.qty end)
      %{state | items: updated_items, total: new_total}
    end)
  end

  def get_items(pid) do
    Agent.get(pid, fn state -> state.items end)
  end

  def clear(pid) do
    Agent.stop(pid)
  end
end

defmodule BillingTax do
  @moduledoc """
  Applies tax rates to the current billing session cart.
  """

  @default_tax_rate 0.07

  def apply(pid, region) do
    rate = tax_rate_for(region)

    Agent.update(pid, fn state ->
      taxed_total = state.total * (1 + rate)
      %{state | tax_rate: rate, total: taxed_total}
    end)
  end

  def current_rate(pid) do
    Agent.get(pid, fn state -> state.tax_rate end)
  end

  defp tax_rate_for("US-CA"), do: 0.0725
  defp tax_rate_for("US-NY"), do: 0.08
  defp tax_rate_for("EU"), do: 0.20
  defp tax_rate_for(_), do: @default_tax_rate
end

defmodule BillingDiscount do
  @moduledoc """
  Applies promotional discounts and coupons to the cart agent.
  """

  @coupons %{
    "SAVE10" => 0.10,
    "SAVE20" => 0.20,
    "FLAT5"  => {:flat, 5.0}
  }

  def apply_coupon(pid, code, user_id) do
    case Map.get(@coupons, code) do
      nil ->
        {:error, :invalid_coupon}

      {:flat, amount} ->
        Agent.update(pid, fn state ->
          new_total = max(0.0, state.total - amount)
          %{state | total: new_total, discounts: [{:flat, code, amount, user_id} | state.discounts]}
        end)
        :ok

      rate ->
        Agent.update(pid, fn state ->
          discount_amount = state.total * rate
          new_total = state.total - discount_amount
          %{state | total: new_total, discounts: [{:percent, code, rate, user_id} | state.discounts]}
        end)
        :ok
    end
  end

  def list_discounts(pid) do
    Agent.get(pid, fn state -> state.discounts end)
  end
end

defmodule BillingCheckout do
  @moduledoc """
  Finalizes a cart and produces an order summary.
  """

  def finalize(pid, customer_id) do
    state = Agent.get(pid, fn s -> s end)

    order = %{
      customer_id: customer_id,
      items: state.items,
      discounts: state.discounts,
      tax_rate: state.tax_rate,
      total: Float.round(state.total, 2),
      finalized_at: DateTime.utc_now()
    }

    Agent.update(pid, fn s -> Map.put(s, :finalized, true) end)

    {:ok, order}
  end

  def is_finalized?(pid) do
    Agent.get(pid, fn state -> Map.get(state, :finalized, false) end)
  end
end
```
