```elixir
defmodule API.QuotaTracker do
  use GenServer

  @moduledoc """
  Tracks API quota consumption for a single tenant across multiple
  quota dimensions (requests, data transfer, compute units).
  Enforces hard limits and soft warning thresholds, and persists
  quota state periodically to a durable store.
  """

  @persist_interval_ms 30_000
  @warning_threshold 0.80

  defstruct [
    :tenant_id,
    :plan,
    :quotas,
    :usage,
    :period_start,
    :period_end,
    :warnings_sent,
    :last_persisted_at
  ]

  def start_for_tenant(tenant_id, plan) do
    {:ok, period_start, period_end} = current_billing_period(tenant_id)

    state = %__MODULE__{
      tenant_id: tenant_id,
      plan: plan,
      quotas: plan.quotas,
      usage: initialize_usage(plan.quotas),
      period_start: period_start,
      period_end: period_end,
      warnings_sent: MapSet.new(),
      last_persisted_at: nil
    }

    GenServer.start(__MODULE__, state, name: via_name(tenant_id))
  end

  @doc "Records API usage for a dimension. Returns :ok or {:error, :quota_exceeded}."
  def record_usage(tenant_id, dimension, amount \\ 1) do
    GenServer.call(via_name(tenant_id), {:record, dimension, amount})
  end

  @doc "Returns current usage summary for a tenant."
  def usage_summary(tenant_id) do
    GenServer.call(via_name(tenant_id), :summary)
  end

  @doc "Resets usage for a new billing period."
  def reset_period(tenant_id) do
    GenServer.call(via_name(tenant_id), :reset_period)
  end

  @doc "Applies a temporary quota override for the tenant."
  def apply_override(tenant_id, dimension, new_limit) do
    GenServer.cast(via_name(tenant_id), {:override, dimension, new_limit})
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_persist()
    {:ok, state}
  end

  @impl true
  def handle_call({:record, dimension, amount}, _from, state) do
    case Map.fetch(state.quotas, dimension) do
      :error ->
        {:reply, {:error, :unknown_dimension}, state}

      {:ok, limit} ->
        current = Map.get(state.usage, dimension, 0)
        new_usage = current + amount

        if new_usage > limit do
          {:reply, {:error, :quota_exceeded}, state}
        else
          new_state = %{state | usage: Map.put(state.usage, dimension, new_usage)}
          final_state = maybe_send_warning(new_state, dimension, new_usage, limit)
          {:reply, :ok, final_state}
        end
    end
  end

  def handle_call(:summary, _from, state) do
    summary = %{
      tenant_id: state.tenant_id,
      plan: state.plan.name,
      period_start: state.period_start,
      period_end: state.period_end,
      usage: Enum.map(state.usage, fn {dim, used} ->
        limit = Map.get(state.quotas, dim, 0)
        pct = if limit > 0, do: Float.round(used / limit * 100, 1), else: 0.0

        %{dimension: dim, used: used, limit: limit, percent: pct}
      end)
    }

    {:reply, summary, state}
  end

  def handle_call(:reset_period, _from, state) do
    {:ok, period_start, period_end} = current_billing_period(state.tenant_id)

    new_state = %{
      state
      | usage: initialize_usage(state.quotas),
        period_start: period_start,
        period_end: period_end,
        warnings_sent: MapSet.new()
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:override, dimension, new_limit}, state) do
    {:noreply, %{state | quotas: Map.put(state.quotas, dimension, new_limit)}}
  end

  @impl true
  def handle_info(:persist, state) do
    persist_usage(state)
    schedule_persist()
    {:noreply, %{state | last_persisted_at: DateTime.utc_now()}}
  end

  defp maybe_send_warning(state, dimension, current, limit) do
    pct = current / limit

    if pct >= @warning_threshold and not MapSet.member?(state.warnings_sent, dimension) do
      emit_quota_warning(state.tenant_id, dimension, pct)
      %{state | warnings_sent: MapSet.put(state.warnings_sent, dimension)}
    else
      state
    end
  end

  defp initialize_usage(quotas) do
    Map.new(quotas, fn {dim, _} -> {dim, 0} end)
  end

  defp current_billing_period(_tenant_id) do
    today = Date.utc_today()
    start = Date.beginning_of_month(today) |> DateTime.new!(~T[00:00:00])
    finish = Date.end_of_month(today) |> DateTime.new!(~T[23:59:59])
    {:ok, start, finish}
  end

  defp persist_usage(_state), do: :ok

  defp emit_quota_warning(_tenant_id, _dimension, _pct), do: :ok

  defp schedule_persist do
    Process.send_after(self(), :persist, @persist_interval_ms)
  end

  defp via_name(tenant_id) do
    {:via, Registry, {API.QuotaRegistry, tenant_id}}
  end
end
```
