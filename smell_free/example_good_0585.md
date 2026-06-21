```elixir
defmodule Gateway.TenantRateLimiter do
  @moduledoc """
  A sliding-window rate limiter scoped per tenant and per endpoint family.

  Each `{tenant_id, bucket}` pair maintains an independent request log.
  Windows are checked by counting requests within the last `window_ms`
  milliseconds. The log is pruned lazily on each check to bound memory.
  """

  use GenServer

  require Logger

  @type tenant_id :: pos_integer() | String.t()
  @type bucket :: atom() | String.t()
  @type check_result :: {:ok, non_neg_integer()} | {:error, :rate_limited}
  @type limit_config :: %{limit: pos_integer(), window_ms: pos_integer()}

  @sweep_interval_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Checks and records a request from `tenant_id` against `bucket`.

  Returns `{:ok, remaining}` with requests remaining in the window, or
  `{:error, :rate_limited}` if the limit is exceeded.
  """
  @spec check(tenant_id(), bucket(), limit_config()) :: check_result()
  def check(tenant_id, bucket, %{limit: limit, window_ms: window_ms}) do
    GenServer.call(__MODULE__, {:check, tenant_id, bucket, limit, window_ms})
  end

  @doc """
  Resets the request log for a specific tenant and bucket.
  Useful for testing or manual operator intervention.
  """
  @spec reset(tenant_id(), bucket()) :: :ok
  def reset(tenant_id, bucket) do
    GenServer.cast(__MODULE__, {:reset, tenant_id, bucket})
  end

  @doc "Returns current usage stats for a tenant/bucket pair."
  @spec usage(tenant_id(), bucket(), pos_integer()) :: %{count: non_neg_integer(), oldest_at: integer() | nil}
  def usage(tenant_id, bucket, window_ms) do
    GenServer.call(__MODULE__, {:usage, tenant_id, bucket, window_ms})
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{windows: %{}}}
  end

  @impl GenServer
  def handle_call({:check, tenant_id, bucket, limit, window_ms}, _from, state) do
    key = {tenant_id, bucket}
    now = now_ms()
    cutoff = now - window_ms

    current_log = Map.get(state.windows, key, [])
    pruned = Enum.drop_while(current_log, &(&1 < cutoff))
    count = length(pruned)

    if count >= limit do
      {:reply, {:error, :rate_limited}, %{state | windows: Map.put(state.windows, key, pruned)}}
    else
      updated = pruned ++ [now]
      {:reply, {:ok, limit - count - 1}, %{state | windows: Map.put(state.windows, key, updated)}}
    end
  end

  @impl GenServer
  def handle_call({:usage, tenant_id, bucket, window_ms}, _from, state) do
    key = {tenant_id, bucket}
    cutoff = now_ms() - window_ms
    log = state.windows |> Map.get(key, []) |> Enum.drop_while(&(&1 < cutoff))
    oldest = List.first(log)
    {:reply, %{count: length(log), oldest_at: oldest}, state}
  end

  @impl GenServer
  def handle_cast({:reset, tenant_id, bucket}, state) do
    {:noreply, %{state | windows: Map.delete(state.windows, {tenant_id, bucket})}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now_ms() - :timer.hours(1)
    pruned = Map.new(state.windows, fn {key, log} ->
      {key, Enum.drop_while(log, &(&1 < cutoff))}
    end)
    empty_keys = Enum.filter(pruned, fn {_, log} -> log == [] end) |> Enum.map(&elem(&1, 0))
    schedule_sweep()
    {:noreply, %{state | windows: Map.drop(pruned, empty_keys)}}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
  defp now_ms, do: :erlang.system_time(:millisecond)
end
```
