```elixir
defmodule Experiments.FeatureFlagServer do
  @moduledoc """
  Serves feature flag evaluations backed by a GenServer that holds flag
  definitions in memory. Flags support boolean kill-switches, percentage
  rollouts, and user-segment targeting. Flag configuration is hot-reloadable
  without restarting the application. Evaluation is deterministic for a
  given user ID so the same user always lands in the same cohort.
  """

  use GenServer

  require Logger

  @type flag_name :: String.t()
  @type user_id :: String.t()
  @type targeting_rule :: %{segment: String.t(), enabled: boolean()}
  @type flag_def :: %{
          enabled: boolean(),
          rollout_pct: non_neg_integer(),
          targeting: [targeting_rule()]
        }

  @doc "Starts the feature flag server, loading flags from application config."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `true` when `flag_name` is enabled for `user_id`. Evaluates
  targeting rules first, then falls back to percentage rollout.
  """
  @spec enabled?(flag_name(), user_id(), [String.t()]) :: boolean()
  def enabled?(flag_name, user_id, user_segments \\ [])
      when is_binary(flag_name) and is_binary(user_id) do
    GenServer.call(__MODULE__, {:evaluate, flag_name, user_id, user_segments})
  end

  @doc "Hot-reloads all flags from the current application configuration."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Adds or replaces a single flag definition at runtime."
  @spec put_flag(flag_name(), flag_def()) :: :ok
  def put_flag(name, definition) when is_binary(name) and is_map(definition) do
    GenServer.cast(__MODULE__, {:put_flag, name, definition})
  end

  @impl GenServer
  def init(opts) do
    flags = Keyword.get(opts, :flags) || load_flags_from_config()
    {:ok, %{flags: flags}}
  end

  @impl GenServer
  def handle_call({:evaluate, name, user_id, segments}, _from, state) do
    result =
      case Map.get(state.flags, name) do
        nil -> false
        %{enabled: false} -> false
        flag -> evaluate_flag(flag, user_id, segments)
      end

    {:reply, result, state}
  end

  def handle_call(:reload, _from, _state) do
    {:reply, :ok, %{flags: load_flags_from_config()}}
  end

  @impl GenServer
  def handle_cast({:put_flag, name, definition}, state) do
    {:noreply, put_in(state, [:flags, name], definition)}
  end

  defp evaluate_flag(%{targeting: [_ | _] = rules} = flag, user_id, segments) do
    matched = Enum.find(rules, fn rule -> rule.segment in segments end)

    case matched do
      %{enabled: val} -> val
      nil -> within_rollout?(flag, user_id)
    end
  end

  defp evaluate_flag(flag, user_id, _segments), do: within_rollout?(flag, user_id)

  defp within_rollout?(%{rollout_pct: pct}, _user_id) when pct >= 100, do: true
  defp within_rollout?(%{rollout_pct: 0}, _user_id), do: false

  defp within_rollout?(%{rollout_pct: pct}, user_id) do
    hash = :erlang.phash2(user_id, 100)
    hash < pct
  end

  defp load_flags_from_config do
    Application.get_env(:my_app, :feature_flags, %{})
  end
end
```
