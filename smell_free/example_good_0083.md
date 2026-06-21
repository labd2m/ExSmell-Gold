# File: `example_good_83.md`

```elixir
defmodule Feature.FlagRegistry do
  @moduledoc """
  In-memory feature flag registry that supports per-flag rollout percentages
  and explicit override lists.

  All flag state is owned by this module exclusively. External modules
  interact only through the defined public API rather than reaching into
  the backing store directly.
  """

  use Agent

  @type flag_name :: atom()
  @type rollout_percent :: 0..100

  @type flag :: %{
          enabled: boolean(),
          rollout_percent: rollout_percent(),
          overrides: %{String.t() => boolean()}
        }

  @type flags :: %{flag_name() => flag()}

  @doc false
  def start_link(initial_flags) when is_map(initial_flags) do
    Agent.start_link(fn -> initial_flags end, name: __MODULE__)
  end

  @doc """
  Returns `true` when the flag is enabled for `actor_id`.

  Evaluation order:
  1. Explicit per-actor override if present.
  2. Rollout bucket check based on actor_id hash.
  3. Global enabled/disabled state.
  """
  @spec enabled?(flag_name(), String.t()) :: boolean()
  def enabled?(flag_name, actor_id)
      when is_atom(flag_name) and is_binary(actor_id) do
    case Agent.get(__MODULE__, &Map.get(&1, flag_name)) do
      nil -> false
      flag -> evaluate_flag(flag, actor_id)
    end
  end

  @doc """
  Registers a new flag or replaces an existing one.
  """
  @spec put(flag_name(), flag()) :: :ok
  def put(flag_name, %{enabled: _, rollout_percent: pct, overrides: overrides} = flag)
      when is_atom(flag_name) and pct in 0..100 and is_map(overrides) do
    Agent.update(__MODULE__, &Map.put(&1, flag_name, flag))
  end

  @doc """
  Sets an explicit override for a specific actor on a given flag.

  Returns `{:error, :unknown_flag}` if the flag does not exist.
  """
  @spec set_override(flag_name(), String.t(), boolean()) ::
          :ok | {:error, :unknown_flag}
  def set_override(flag_name, actor_id, value)
      when is_atom(flag_name) and is_binary(actor_id) and is_boolean(value) do
    Agent.get_and_update(__MODULE__, fn flags ->
      case Map.fetch(flags, flag_name) do
        {:ok, flag} ->
          updated_flag = put_in(flag, [:overrides, actor_id], value)
          {:ok, Map.put(flags, flag_name, updated_flag)}

        :error ->
          {{:error, :unknown_flag}, flags}
      end
    end)
  end

  @doc """
  Removes the override for a specific actor on a flag, falling back to
  rollout-based evaluation.
  """
  @spec clear_override(flag_name(), String.t()) :: :ok | {:error, :unknown_flag}
  def clear_override(flag_name, actor_id)
      when is_atom(flag_name) and is_binary(actor_id) do
    Agent.get_and_update(__MODULE__, fn flags ->
      case Map.fetch(flags, flag_name) do
        {:ok, flag} ->
          updated_flag = update_in(flag, [:overrides], &Map.delete(&1, actor_id))
          {:ok, Map.put(flags, flag_name, updated_flag)}

        :error ->
          {{:error, :unknown_flag}, flags}
      end
    end)
  end

  @doc """
  Deletes a flag from the registry entirely.
  """
  @spec delete(flag_name()) :: :ok
  def delete(flag_name) when is_atom(flag_name) do
    Agent.update(__MODULE__, &Map.delete(&1, flag_name))
  end

  @doc """
  Returns the complete flag definition for `flag_name`.

  Returns `{:ok, flag}` or `{:error, :unknown_flag}`.
  """
  @spec fetch(flag_name()) :: {:ok, flag()} | {:error, :unknown_flag}
  def fetch(flag_name) when is_atom(flag_name) do
    case Agent.get(__MODULE__, &Map.get(&1, flag_name)) do
      nil -> {:error, :unknown_flag}
      flag -> {:ok, flag}
    end
  end

  defp evaluate_flag(%{overrides: overrides} = flag, actor_id) do
    case Map.fetch(overrides, actor_id) do
      {:ok, override_value} -> override_value
      :error -> check_rollout(flag, actor_id)
    end
  end

  defp check_rollout(%{enabled: false}, _actor_id), do: false

  defp check_rollout(%{rollout_percent: 100}, _actor_id), do: true

  defp check_rollout(%{rollout_percent: 0}, _actor_id), do: false

  defp check_rollout(%{rollout_percent: pct}, actor_id) do
    bucket = :erlang.phash2(actor_id, 100)
    bucket < pct
  end
end
```
