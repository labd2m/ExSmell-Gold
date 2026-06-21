```elixir
defmodule Subscriptions.BillingCycleServer do
  @moduledoc """
  Manages subscription billing cycles as a GenServer aggregate. Each cycle
  records its start date, renewal date, current status, and usage counters.
  The server enforces valid transitions and emits telemetry events on every
  status change so billing analytics remain decoupled from cycle logic.
  """

  use GenServer

  require Logger

  @type cycle_status :: :active | :past_due | :cancelled | :expired
  @type state :: %{
          subscription_id: String.t(),
          plan_id: String.t(),
          status: cycle_status(),
          starts_on: Date.t(),
          renews_on: Date.t(),
          usage: %{atom() => non_neg_integer()},
          events: [map()]
        }

  @transition_event [:my_app, :billing, :cycle_transition]

  @doc "Starts the billing cycle server registered via a Registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    sub_id = Keyword.fetch!(opts, :subscription_id)
    GenServer.start_link(__MODULE__, opts, name: via(sub_id))
  end

  @doc "Increments a named usage counter for the current cycle."
  @spec record_usage(String.t(), atom(), pos_integer()) :: :ok
  def record_usage(sub_id, metric, amount)
      when is_binary(sub_id) and is_atom(metric) and is_integer(amount) and amount > 0 do
    GenServer.cast(via(sub_id), {:record_usage, metric, amount})
  end

  @doc "Transitions the cycle to past_due status."
  @spec mark_past_due(String.t()) :: :ok | {:error, :invalid_transition}
  def mark_past_due(sub_id) when is_binary(sub_id) do
    GenServer.call(via(sub_id), {:transition, :past_due})
  end

  @doc "Cancels the subscription cycle."
  @spec cancel(String.t()) :: :ok | {:error, :invalid_transition}
  def cancel(sub_id) when is_binary(sub_id) do
    GenServer.call(via(sub_id), {:transition, :cancelled})
  end

  @doc "Returns the current cycle snapshot."
  @spec snapshot(String.t()) :: state()
  def snapshot(sub_id) when is_binary(sub_id) do
    GenServer.call(via(sub_id), :snapshot)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      subscription_id: Keyword.fetch!(opts, :subscription_id),
      plan_id: Keyword.fetch!(opts, :plan_id),
      status: :active,
      starts_on: Keyword.get(opts, :starts_on, Date.utc_today()),
      renews_on: Keyword.fetch!(opts, :renews_on),
      usage: %{},
      events: []
    }
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:record_usage, metric, amount}, state) do
    new_usage = Map.update(state.usage, metric, amount, &(&1 + amount))
    {:noreply, %{state | usage: new_usage}}
  end

  @impl GenServer
  def handle_call({:transition, new_status}, _from, state) do
    if valid_transition?(state.status, new_status) do
      emit_transition(state, new_status)
      entry = %{from: state.status, to: new_status, at: DateTime.utc_now()}
      {:reply, :ok, %{state | status: new_status, events: [entry | state.events]}}
    else
      {:reply, {:error, :invalid_transition}, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  defp valid_transition?(:active, :past_due), do: true
  defp valid_transition?(:active, :cancelled), do: true
  defp valid_transition?(:past_due, :active), do: true
  defp valid_transition?(:past_due, :cancelled), do: true
  defp valid_transition?(:past_due, :expired), do: true
  defp valid_transition?(_, _), do: false

  defp emit_transition(%{subscription_id: sid}, new_status) do
    :telemetry.execute(@transition_event, %{system_time: System.system_time()},
      %{subscription_id: sid, new_status: new_status})
  end

  defp via(sub_id), do: {:via, Registry, {Subscriptions.CycleRegistry, sub_id}}
end
```
