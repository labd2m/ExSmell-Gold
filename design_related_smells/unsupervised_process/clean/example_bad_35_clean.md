```elixir
defmodule SubscriptionProcess do
  use GenServer

  @moduledoc """
  Manages the lifecycle of a single customer subscription including
  billing cycle tracking, renewal scheduling, and dunning management.
  """

  @dunning_intervals_days [3, 7, 14]

  defstruct [
    :subscription_id,
    :customer_id,
    :plan,
    :status,
    :current_period_start,
    :current_period_end,
    :renewal_attempts,
    :payment_method_id,
    dunning_step: 0
  ]

  def start(%{subscription_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def cancel(subscription_id, reason \\ :user_requested) do
    GenServer.call(via(subscription_id), {:cancel, reason})
  end

  def upgrade(subscription_id, new_plan) do
    GenServer.call(via(subscription_id), {:upgrade, new_plan})
  end

  def get(subscription_id) do
    GenServer.call(via(subscription_id), :get)
  end

  def force_renew(subscription_id) do
    GenServer.call(via(subscription_id), :renew)
  end

  defp via(id), do: {:via, Registry, {SubscriptionRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{subscription_id: id, customer_id: cid, plan: plan, payment_method_id: pmid}) do
    now = DateTime.utc_now()
    period_end = DateTime.add(now, period_days(plan), :day)

    state = %__MODULE__{
      subscription_id: id,
      customer_id: cid,
      plan: plan,
      status: :active,
      current_period_start: now,
      current_period_end: period_end,
      renewal_attempts: 0,
      payment_method_id: pmid
    }

    schedule_renewal(period_end)
    {:ok, state}
  end

  @impl true
  def handle_call({:cancel, _reason}, _from, state) do
    {:reply, :ok, %{state | status: :cancelled}}
  end

  def handle_call({:upgrade, new_plan}, _from, state) do
    now = DateTime.utc_now()
    period_end = DateTime.add(now, period_days(new_plan), :day)
    updated = %{state | plan: new_plan, current_period_start: now, current_period_end: period_end}
    schedule_renewal(period_end)
    {:reply, :ok, updated}
  end

  def handle_call(:get, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:renew, _from, state) do
    handle_renewal(state)
  end

  @impl true
  def handle_info(:renew, state) do
    {reply, _new_state} = handle_renewal(state)
    IO.inspect(reply, label: "[SubscriptionProcess] renewal result for #{state.subscription_id}")
    {:noreply, _new_state}
  end

  defp handle_renewal(%{status: :cancelled} = state) do
    {{:error, :cancelled}, state}
  end

  defp handle_renewal(state) do
    case attempt_charge(state.customer_id, state.plan, state.payment_method_id) do
      :ok ->
        now = DateTime.utc_now()
        period_end = DateTime.add(now, period_days(state.plan), :day)
        updated = %{state | current_period_start: now, current_period_end: period_end, renewal_attempts: 0, dunning_step: 0}
        schedule_renewal(period_end)
        {{:ok, :renewed}, updated}

      {:error, _reason} ->
        updated = %{state | renewal_attempts: state.renewal_attempts + 1}
        schedule_dunning(updated)
        {{:error, :payment_failed}, updated}
    end
  end

  defp attempt_charge(_cid, _plan, _pm), do: :ok

  defp schedule_renewal(period_end) do
    ms = max(0, DateTime.diff(period_end, DateTime.utc_now(), :millisecond))
    Process.send_after(self(), :renew, ms)
  end

  defp schedule_dunning(%{dunning_step: step}) when step < length(@dunning_intervals_days) do
    days = Enum.at(@dunning_intervals_days, step)
    Process.send_after(self(), :renew, days * 86_400_000)
  end

  defp schedule_dunning(_state), do: :ok

  defp period_days(:monthly), do: 30
  defp period_days(:annual), do: 365
  defp period_days(_), do: 30
end

defmodule SubscriptionManager do
  @moduledoc "Public API for managing customer subscriptions."

  def activate(%{subscription_id: _id, customer_id: _cid, plan: _plan, payment_method_id: _pm} = attrs) do
    case SubscriptionProcess.start(attrs) do
      {:ok, _pid} -> {:ok, attrs.subscription_id}
      {:error, {:already_started, _}} -> {:ok, attrs.subscription_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel(subscription_id) do
    SubscriptionProcess.cancel(subscription_id)
  end
end
```
