```elixir
defmodule Config.FeatureFlags do
  @moduledoc """
  Runtime feature flag store backed by ETS for lock-free concurrent reads.
  Flags can be toggled globally or scoped to specific tenant IDs.
  """

  use GenServer

  @table :feature_flags

  @type flag_name :: String.t()
  @type scope :: :global | {:tenant, String.t()}
  @type flag_state :: %{enabled: boolean(), rollout_percent: non_neg_integer()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enabled?(flag_name(), String.t()) :: boolean()
  def enabled?(flag, tenant_id) when is_binary(flag) and is_binary(tenant_id) do
    tenant_scope = {:tenant, tenant_id}

    case lookup_flag(flag, tenant_scope) do
      {:ok, state} -> evaluate_rollout(state, tenant_id)
      {:error, :not_found} -> evaluate_global(flag, tenant_id)
    end
  end

  @spec set(flag_name(), boolean(), scope(), non_neg_integer()) :: :ok
  def set(flag, enabled, scope \\ :global, rollout_percent \\ 100)
      when is_binary(flag) and is_boolean(enabled) and rollout_percent in 0..100 do
    GenServer.call(__MODULE__, {:set, flag, scope, %{enabled: enabled, rollout_percent: rollout_percent}})
  end

  @spec delete(flag_name(), scope()) :: :ok
  def delete(flag, scope \\ :global) when is_binary(flag) do
    GenServer.call(__MODULE__, {:delete, flag, scope})
  end

  @spec all_flags() :: [{flag_name(), scope(), flag_state()}]
  def all_flags do
    :ets.tab2list(@table)
    |> Enum.map(fn {{name, scope}, state} -> {name, scope, state} end)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:set, flag, scope, state}, _from, gen_state) do
    :ets.insert(@table, {{flag, scope}, state})
    {:reply, :ok, gen_state}
  end

  def handle_call({:delete, flag, scope}, _from, gen_state) do
    :ets.delete(@table, {flag, scope})
    {:reply, :ok, gen_state}
  end

  @spec lookup_flag(flag_name(), scope()) :: {:ok, flag_state()} | {:error, :not_found}
  defp lookup_flag(flag, scope) do
    case :ets.lookup(@table, {flag, scope}) do
      [{{^flag, ^scope}, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  @spec evaluate_global(flag_name(), String.t()) :: boolean()
  defp evaluate_global(flag, tenant_id) do
    case lookup_flag(flag, :global) do
      {:ok, state} -> evaluate_rollout(state, tenant_id)
      {:error, :not_found} -> false
    end
  end

  @spec evaluate_rollout(flag_state(), String.t()) :: boolean()
  defp evaluate_rollout(%{enabled: false}, _tenant_id), do: false
  defp evaluate_rollout(%{enabled: true, rollout_percent: 100}, _tenant_id), do: true

  defp evaluate_rollout(%{enabled: true, rollout_percent: percent}, tenant_id) do
    bucket = :erlang.phash2(tenant_id, 100)
    bucket < percent
  end
end
```
