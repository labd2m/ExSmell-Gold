```elixir
defmodule Inventory.ReorderAdvisor do
  use GenServer

  @moduledoc """
  Computes reorder points, economic order quantities, and stock projections
  for the inventory management system. Used by the purchasing dashboard and
  automated restocking jobs.
  """



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Computes the reorder point for a SKU.
  `params` must include `:avg_daily_demand`, `:lead_time_days`, `:safety_stock`.
  """
  def reorder_point(pid, params) do
    GenServer.call(pid, {:reorder_point, params})
  end

  @doc """
  Computes the Economic Order Quantity (Wilson formula).
  `params` must include `:annual_demand`, `:order_cost`, `:holding_cost_per_unit`.
  """
  def economic_order_quantity(pid, params) do
    GenServer.call(pid, {:eoq, params})
  end

  @doc """
  Returns the estimated number of days of remaining stock.
  `params` must include `:current_stock`, `:avg_daily_demand`.
  """
  def days_of_stock(pid, params) do
    GenServer.call(pid, {:days_of_stock, params})
  end

  @doc """
  Returns `{:ok, true}` if current stock is at or below the reorder point.
  `params` must include all fields for `reorder_point/2` plus `:current_stock`.
  """
  def reorder_required?(pid, params) do
    GenServer.call(pid, {:reorder_required, params})
  end

  @doc """
  Returns a full advisory summary for a SKU.
  """
  def advisory(pid, params) do
    GenServer.call(pid, {:advisory, params})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:reorder_point, params}, _from, state) do
    rop =
      params.avg_daily_demand * params.lead_time_days + params.safety_stock

    {:reply, {:ok, Float.round(rop, 2)}, state}
  end

  @impl true
  def handle_call({:eoq, params}, _from, state) do
    numerator = 2 * params.annual_demand * params.order_cost
    eoq = :math.sqrt(numerator / params.holding_cost_per_unit)
    {:reply, {:ok, Float.round(eoq, 2)}, state}
  end

  @impl true
  def handle_call({:days_of_stock, params}, _from, state) do
    days =
      if params.avg_daily_demand > 0 do
        params.current_stock / params.avg_daily_demand
      else
        :infinity
      end

    {:reply, {:ok, Float.round(days / 1, 1)}, state}
  end

  @impl true
  def handle_call({:reorder_required, params}, _from, state) do
    rop = params.avg_daily_demand * params.lead_time_days + params.safety_stock
    {:reply, {:ok, params.current_stock <= rop}, state}
  end

  @impl true
  def handle_call({:advisory, params}, _from, state) do
    rop = params.avg_daily_demand * params.lead_time_days + params.safety_stock

    eoq =
      if Map.has_key?(params, :annual_demand) do
        :math.sqrt(2 * params.annual_demand * params.order_cost / params.holding_cost_per_unit)
      else
        nil
      end

    days =
      if params.avg_daily_demand > 0,
        do: Float.round(params.current_stock / params.avg_daily_demand, 1),
        else: :infinity

    result = %{
      sku: Map.get(params, :sku, "unknown"),
      current_stock: params.current_stock,
      reorder_point: Float.round(rop, 2),
      days_of_stock: days,
      eoq: if(eoq, do: Float.round(eoq, 2), else: nil),
      reorder_required: params.current_stock <= rop,
      urgency: classify_urgency(params.current_stock, rop, days)
    }

    {:reply, {:ok, result}, state}
  end

  defp classify_urgency(stock, rop, days) do
    cond do
      stock <= 0 -> :critical
      stock <= rop * 0.5 -> :high
      stock <= rop -> :medium
      days < 14 -> :low
      true -> :none
    end
  end
end
```
