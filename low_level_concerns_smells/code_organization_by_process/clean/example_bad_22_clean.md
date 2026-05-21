```elixir
defmodule Payments.FeeCalculator do
  use GenServer

  @moduledoc """
  Calculates payment processing fees for various payment methods and gateways.
  Used by the checkout flow, payout service, and finance reconciliation reports.
  """

  @fee_schedules %{
    "stripe_card" => %{
      percent: 0.029,
      fixed: 0.30,
      international_surcharge: 0.015,
      currency: "USD"
    },
    "stripe_ach" => %{
      percent: 0.008,
      fixed: 0.00,
      cap: 5.00,
      currency: "USD"
    },
    "paypal" => %{
      percent: 0.0349,
      fixed: 0.49,
      international_surcharge: 0.015,
      currency: "USD"
    },
    "wire_transfer" => %{
      percent: 0.0,
      fixed: 25.00,
      currency: "USD"
    },
    "crypto_usdc" => %{
      percent: 0.005,
      fixed: 0.00,
      currency: "USD"
    }
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, @fee_schedules, opts)
  end

  @doc """
  Returns the processing fee for `amount` charged via `method`.
  Pass `international: true` to apply international surcharges where applicable.
  """
  def processing_fee(pid, amount, method, opts \\ []) do
    GenServer.call(pid, {:processing_fee, amount, method, opts})
  end

  @doc """
  Returns the net payout amount after fees are deducted.
  """
  def net_payout(pid, amount, method, opts \\ []) do
    GenServer.call(pid, {:net_payout, amount, method, opts})
  end

  @doc """
  Returns a detailed fee breakdown map.
  """
  def fee_breakdown(pid, amount, method, opts \\ []) do
    GenServer.call(pid, {:fee_breakdown, amount, method, opts})
  end

  @doc """
  Compares fees across all payment methods for a given amount.
  Returns a sorted list from lowest to highest fee.
  """
  def compare_methods(pid, amount, opts \\ []) do
    GenServer.call(pid, {:compare_methods, amount, opts})
  end

  ## GenServer Callbacks

  @impl true
  def init(schedules), do: {:ok, schedules}

  @impl true
  def handle_call({:processing_fee, amount, method, opts}, _from, schedules) do
    result =
      case Map.get(schedules, method) do
        nil -> {:error, "Unknown payment method: #{method}"}
        schedule -> {:ok, compute_fee(amount, schedule, opts)}
      end

    {:reply, result, schedules}
  end

  @impl true
  def handle_call({:net_payout, amount, method, opts}, _from, schedules) do
    result =
      case Map.get(schedules, method) do
        nil -> {:error, "Unknown payment method: #{method}"}
        schedule ->
          fee = compute_fee(amount, schedule, opts)
          {:ok, Float.round(amount - fee, 2)}
      end

    {:reply, result, schedules}
  end

  @impl true
  def handle_call({:fee_breakdown, amount, method, opts}, _from, schedules) do
    result =
      case Map.get(schedules, method) do
        nil ->
          {:error, "Unknown payment method: #{method}"}

        schedule ->
          international = Keyword.get(opts, :international, false)
          percent_fee = Float.round(amount * schedule.percent, 2)
          fixed_fee = Map.get(schedule, :fixed, 0.0)
          surcharge = if international, do: amount * Map.get(schedule, :international_surcharge, 0.0), else: 0.0
          raw_fee = percent_fee + fixed_fee + surcharge
          capped_fee = if Map.has_key?(schedule, :cap), do: min(raw_fee, schedule.cap), else: raw_fee
          total_fee = Float.round(capped_fee, 2)

          {:ok,
           %{
             method: method,
             gross_amount: amount,
             percent_fee: percent_fee,
             fixed_fee: fixed_fee,
             surcharge: Float.round(surcharge, 2),
             total_fee: total_fee,
             net_payout: Float.round(amount - total_fee, 2)
           }}
      end

    {:reply, result, schedules}
  end

  @impl true
  def handle_call({:compare_methods, amount, opts}, _from, schedules) do
    comparison =
      schedules
      |> Enum.map(fn {method, schedule} ->
        fee = compute_fee(amount, schedule, opts)
        %{method: method, fee: fee, net_payout: Float.round(amount - fee, 2)}
      end)
      |> Enum.sort_by(& &1.fee)

    {:reply, {:ok, comparison}, schedules}
  end


  defp compute_fee(amount, schedule, opts) do
    international = Keyword.get(opts, :international, false)
    percent_fee = amount * schedule.percent
    fixed_fee = Map.get(schedule, :fixed, 0.0)
    surcharge = if international, do: amount * Map.get(schedule, :international_surcharge, 0.0), else: 0.0
    raw = percent_fee + fixed_fee + surcharge
    capped = if Map.has_key?(schedule, :cap), do: min(raw, schedule.cap), else: raw
    Float.round(capped, 2)
  end
end
```
