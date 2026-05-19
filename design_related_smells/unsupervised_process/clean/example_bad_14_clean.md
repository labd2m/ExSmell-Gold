```elixir
defmodule FeatureFlags.Store do
  use GenServer

  @moduledoc """
  Central in-memory store for feature flag definitions and rollout state.
  Supports boolean flags, percentage rollouts, and per-segment overrides.
  Periodically syncs from a remote configuration source.
  """

  @sync_interval_ms 60_000
  @default_rollout_salt "feature_flag_v1"

  defstruct [
    :flags,
    :overrides,
    :last_sync_at,
    :sync_count
  ]

  def start do
    GenServer.start(__MODULE__, %__MODULE__{flags: %{}, overrides: %{}, sync_count: 0},
      name: __MODULE__
    )
  end

  @doc "Returns true if `flag` is enabled for the given context."
  def enabled?(flag_name, context \\ %{}) do
    GenServer.call(__MODULE__, {:evaluate, flag_name, context})
  end

  @doc "Defines or updates a feature flag."
  def put_flag(flag_name, config) do
    GenServer.call(__MODULE__, {:put_flag, flag_name, config})
  end

  @doc "Removes a feature flag."
  def delete_flag(flag_name) do
    GenServer.cast(__MODULE__, {:delete_flag, flag_name})
  end

  @doc "Sets a per-entity override for a flag."
  def set_override(flag_name, entity_id, value) when is_boolean(value) do
    GenServer.call(__MODULE__, {:set_override, flag_name, entity_id, value})
  end

  @doc "Clears all overrides for a flag."
  def clear_overrides(flag_name) do
    GenServer.cast(__MODULE__, {:clear_overrides, flag_name})
  end

  @doc "Forces an immediate configuration sync."
  def sync do
    GenServer.call(__MODULE__, :sync, 15_000)
  end

  @doc "Returns all flag definitions and their current state."
  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  ## Callbacks

  @impl true
  def init(state) do
    send(self(), :sync)
    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate, flag_name, context}, _from, state) do
    result =
      case Map.fetch(state.overrides, {flag_name, context[:entity_id]}) do
        {:ok, override} ->
          override

        :error ->
          case Map.fetch(state.flags, flag_name) do
            {:ok, flag} -> evaluate_flag(flag, context)
            :error -> false
          end
      end

    {:reply, result, state}
  end

  def handle_call({:put_flag, flag_name, config}, _from, state) do
    validated = validate_flag_config(config)
    {:reply, validated, %{state | flags: Map.put(state.flags, flag_name, config)}}
  end

  def handle_call({:set_override, flag_name, entity_id, value}, _from, state) do
    key = {flag_name, entity_id}
    {:reply, :ok, %{state | overrides: Map.put(state.overrides, key, value)}}
  end

  def handle_call(:sync, _from, state) do
    new_state = do_sync(state)
    {:reply, {:ok, new_state.last_sync_at}, new_state}
  end

  def handle_call(:dump, _from, state) do
    {:reply, %{flags: state.flags, last_sync_at: state.last_sync_at}, state}
  end

  @impl true
  def handle_cast({:delete_flag, flag_name}, state) do
    {:noreply, %{state | flags: Map.delete(state.flags, flag_name)}}
  end

  def handle_cast({:clear_overrides, flag_name}, state) do
    new_overrides =
      Enum.reject(state.overrides, fn {{name, _}, _} -> name == flag_name end)
      |> Map.new()

    {:noreply, %{state | overrides: new_overrides}}
  end

  @impl true
  def handle_info(:sync, state) do
    new_state = do_sync(state)
    Process.send_after(self(), :sync, @sync_interval_ms)
    {:noreply, new_state}
  end

  defp evaluate_flag(%{type: :boolean, enabled: enabled}, _context), do: enabled

  defp evaluate_flag(%{type: :percentage, rollout: pct}, %{entity_id: entity_id})
       when not is_nil(entity_id) do
    hash =
      :crypto.hash(:sha256, "#{@default_rollout_salt}:#{entity_id}")
      |> :binary.decode_unsigned()

    rem(hash, 100) < pct
  end

  defp evaluate_flag(%{type: :percentage}, _context), do: false

  defp evaluate_flag(%{type: :segment, segments: segs}, %{segment: segment}) do
    segment in segs
  end

  defp evaluate_flag(_flag, _context), do: false

  defp validate_flag_config(%{type: :boolean, enabled: val}) when is_boolean(val), do: :ok
  defp validate_flag_config(%{type: :percentage, rollout: pct}) when pct in 0..100, do: :ok
  defp validate_flag_config(%{type: :segment, segments: segs}) when is_list(segs), do: :ok
  defp validate_flag_config(_), do: {:error, :invalid_config}

  defp do_sync(state) do
    # Simulated remote sync
    %{state | last_sync_at: DateTime.utc_now(), sync_count: state.sync_count + 1}
  end
end
```
