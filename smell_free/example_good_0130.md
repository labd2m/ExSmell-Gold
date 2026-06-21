```elixir
defmodule MyApp.FeatureFlags do
  @moduledoc """
  A persistent feature flag store backed by ETS for fast reads and a
  GenServer for serialized writes. Flags are loaded from the database
  on startup and can be toggled at runtime without a deploy. Subscribers
  receive a PubSub notification whenever a flag changes, enabling live
  UI updates or cache invalidation downstream.

  Start this module under the application supervisor:

      children = [MyApp.FeatureFlags]
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Config.FeatureFlag

  @table __MODULE__
  @pubsub MyApp.PubSub
  @topic "feature_flags"

  @type flag_name :: String.t()
  @type flag_value :: boolean() | String.t() | number()

  @doc "Starts the feature flag server and preloads all flags."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the value of `flag_name`, or `default` when the flag is not set.
  This call reads directly from ETS and never blocks on the GenServer.
  """
  @spec get(flag_name(), flag_value()) :: flag_value()
  def get(flag_name, default \\ false) when is_binary(flag_name) do
    case :ets.lookup(@table, flag_name) do
      [{^flag_name, value}] -> value
      [] -> default
    end
  end

  @doc "Returns `true` if the flag exists and is set to a truthy value."
  @spec enabled?(flag_name()) :: boolean()
  def enabled?(flag_name) when is_binary(flag_name) do
    case get(flag_name, false) do
      false -> false
      nil -> false
      _truthy -> true
    end
  end

  @doc """
  Persists and broadcasts a new value for `flag_name`.
  Blocks until the write is committed.
  """
  @spec set(flag_name(), flag_value()) :: :ok | {:error, term()}
  def set(flag_name, value) when is_binary(flag_name) do
    GenServer.call(__MODULE__, {:set, flag_name, value})
  end

  @doc "Subscribes the calling process to flag change notifications."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    load_from_db()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:set, flag_name, value}, _from, state) do
    result =
      with {:ok, _flag} <- upsert_flag(flag_name, value) do
        :ets.insert(@table, {flag_name, value})
        broadcast_change(flag_name, value)
        :ok
      end

    {:reply, result, state}
  end

  @spec load_from_db() :: :ok
  defp load_from_db do
    FeatureFlag
    |> Repo.all()
    |> Enum.each(fn flag ->
      :ets.insert(@table, {flag.name, flag.value})
    end)
  end

  @spec upsert_flag(flag_name(), flag_value()) ::
          {:ok, FeatureFlag.t()} | {:error, Ecto.Changeset.t()}
  defp upsert_flag(name, value) do
    %FeatureFlag{}
    |> FeatureFlag.changeset(%{name: name, value: value})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :name
    )
  end

  @spec broadcast_change(flag_name(), flag_value()) :: :ok | {:error, term()}
  defp broadcast_change(name, value) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flag_changed, name, value})
  end
end
```
