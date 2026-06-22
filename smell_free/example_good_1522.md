```elixir
defmodule Config.FeatureFlags do
  @moduledoc """
  Runtime feature flag resolution for controlling gradual feature rollouts.

  Flag values are resolved at call time from a backing store (ETS or
  remote config), with an in-process ETS table used as a low-latency
  read cache. All write operations go through the `FlagStore` context.
  """

  use GenServer

  alias Config.FlagStore

  @table_name :feature_flags_cache
  @sync_interval_ms 30_000

  @type flag_name :: atom()
  @type flag_value :: boolean() | {:percentage, 0..100}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `true` if the given flag is enabled for the optional context.

  Percentage-rollout flags evaluate against the provided `rollout_key`
  (e.g., a user ID) to ensure consistent assignment.
  """
  @spec enabled?(flag_name(), String.t() | nil) :: boolean()
  def enabled?(flag, rollout_key \\ nil) when is_atom(flag) do
    case :ets.lookup(@table_name, flag) do
      [{^flag, value}] -> resolve_value(value, rollout_key)
      [] -> false
    end
  end

  @doc """
  Forces an immediate re-sync of the flag cache from the backing store.
  """
  @spec sync() :: :ok
  def sync do
    GenServer.call(__MODULE__, :sync)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    load_flags()
    schedule_sync()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:sync, _from, state) do
    load_flags()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:scheduled_sync, state) do
    load_flags()
    schedule_sync()
    {:noreply, state}
  end

  @spec load_flags() :: :ok
  defp load_flags do
    flags = FlagStore.all_flags()

    :ets.delete_all_objects(@table_name)

    Enum.each(flags, fn {name, value} ->
      :ets.insert(@table_name, {name, value})
    end)

    :ok
  end

  @spec resolve_value(flag_value(), String.t() | nil) :: boolean()
  defp resolve_value(true, _), do: true
  defp resolve_value(false, _), do: false

  defp resolve_value({:percentage, pct}, nil) do
    :rand.uniform(100) <= pct
  end

  defp resolve_value({:percentage, pct}, rollout_key) when is_binary(rollout_key) do
    bucket = hash_to_bucket(rollout_key)
    bucket <= pct
  end

  @spec hash_to_bucket(String.t()) :: 1..100
  defp hash_to_bucket(key) do
    <<hash::integer-size(32), _::binary>> = :crypto.hash(:md5, key)
    rem(abs(hash), 100) + 1
  end

  @spec schedule_sync() :: reference()
  defp schedule_sync do
    Process.send_after(self(), :scheduled_sync, @sync_interval_ms)
  end
end
```
