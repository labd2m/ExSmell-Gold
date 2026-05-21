```elixir
defmodule Billing.CycleCalculator do
  use GenServer

  @moduledoc """
  Computes subscription billing cycle dates, proration amounts, and annual costs.
  Used by the subscription service during plan activation, upgrades, and billing runs.
  """

  @billing_intervals %{
    monthly: 1,
    quarterly: 3,
    semiannual: 6,
    annual: 12
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns the next billing date after `anchor_date` for the given `interval`.
  """
  def next_billing_date(pid, anchor_date, interval) do
    GenServer.call(pid, {:next_billing_date, anchor_date, interval})
  end

  @doc """
  Computes the prorated charge when switching plans mid-cycle.
  `params` must include `:old_plan_price`, `:new_plan_price`, `:cycle_start`,
  `:cycle_end`, and `:change_date`.
  """
  def prorate(pid, params) do
    GenServer.call(pid, {:prorate, params})
  end

  @doc """
  Returns `{cycle_start, cycle_end}` for the current billing cycle
  that contains `reference_date`.
  """
  def cycle_dates(pid, anchor_date, interval, reference_date \\ Date.utc_today()) do
    GenServer.call(pid, {:cycle_dates, anchor_date, interval, reference_date})
  end

  @doc """
  Returns the total annual cost for a plan on a given billing interval.
  """
  def annual_cost(pid, plan_price, interval) do
    GenServer.call(pid, {:annual_cost, plan_price, interval})
  end

  @doc """
  Returns the number of billing cycles per year for an interval.
  """
  def cycles_per_year(pid, interval) do
    GenServer.call(pid, {:cycles_per_year, interval})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:next_billing_date, anchor, interval}, _from, state) do
    months = Map.get(@billing_intervals, interval)

    result =
      case months do
        nil -> {:error, "Unknown billing interval: #{interval}"}
        m -> {:ok, shift_months(anchor, m)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:prorate, params}, _from, state) do
    cycle_days = Date.diff(params.cycle_end, params.cycle_start)
    remaining_days = Date.diff(params.cycle_end, params.change_date)

    result =
      if cycle_days <= 0 do
        {:error, "Invalid cycle: end must be after start"}
      else
        old_daily = params.old_plan_price / cycle_days
        new_daily = params.new_plan_price / cycle_days
        credit = Float.round(old_daily * remaining_days, 2)
        charge = Float.round(new_daily * remaining_days, 2)
        adjustment = Float.round(charge - credit, 2)

        {:ok,
         %{
           credit: credit,
           charge: charge,
           net_adjustment: adjustment,
           remaining_days: remaining_days,
           cycle_days: cycle_days
         }}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:cycle_dates, anchor, interval, reference}, _from, state) do
    months = Map.get(@billing_intervals, interval)

    result =
      case months do
        nil ->
          {:error, "Unknown billing interval: #{interval}"}

        m ->
          cycle_start = find_cycle_start(anchor, m, reference)
          cycle_end = shift_months(cycle_start, m)
          {:ok, %{start: cycle_start, end: cycle_end}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:annual_cost, plan_price, interval}, _from, state) do
    result =
      case Map.get(@billing_intervals, interval) do
        nil -> {:error, "Unknown billing interval: #{interval}"}
        months ->
          cycles = div(12, months)
          {:ok, Float.round(plan_price * cycles, 2)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:cycles_per_year, interval}, _from, state) do
    result =
      case Map.get(@billing_intervals, interval) do
        nil -> {:error, "Unknown billing interval: #{interval}"}
        months -> {:ok, div(12, months)}
      end

    {:reply, result, state}
  end


  defp shift_months(date, months) do
    total_months = date.month + months
    years_to_add = div(total_months - 1, 12)
    new_month = rem(total_months - 1, 12) + 1
    new_year = date.year + years_to_add
    max_day = :calendar.last_day_of_the_month(new_year, new_month)
    Date.new!(new_year, new_month, min(date.day, max_day))
  end

  defp find_cycle_start(anchor, interval_months, reference) do
    start = anchor

    Stream.iterate(start, &shift_months(&1, interval_months))
    |> Stream.take_while(&(Date.compare(&1, reference) != :gt))
    |> Enum.to_list()
    |> List.last()
  end
end
```
