```elixir
defmodule Platform.FeatureRegistry do
  @moduledoc """
  Maintains a registry of named application features with their enablement
  state and metadata. Features can be toggled at runtime without restarting
  the application. Each feature entry records when it was last modified and
  by which operator for audit purposes.
  """

  use GenServer

  require Logger

  @type feature_name :: String.t()
  @type feature_entry :: %{
          name: feature_name(),
          enabled: boolean(),
          description: String.t(),
          modified_by: String.t() | nil,
          modified_at: DateTime.t()
        }

  @doc "Starts the feature registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a new feature with an initial enabled state."
  @spec register(feature_name(), boolean(), String.t()) :: :ok | {:error, :already_registered}
  def register(name, enabled, description)
      when is_binary(name) and is_boolean(enabled) and is_binary(description) do
    GenServer.call(__MODULE__, {:register, name, enabled, description})
  end

  @doc "Enables a previously registered feature."
  @spec enable(feature_name(), String.t()) :: :ok | {:error, :not_found}
  def enable(name, operator) when is_binary(name) and is_binary(operator) do
    GenServer.call(__MODULE__, {:set_enabled, name, true, operator})
  end

  @doc "Disables a previously registered feature."
  @spec disable(feature_name(), String.t()) :: :ok | {:error, :not_found}
  def disable(name, operator) when is_binary(name) and is_binary(operator) do
    GenServer.call(__MODULE__, {:set_enabled, name, false, operator})
  end

  @doc "Returns true when the named feature is enabled."
  @spec enabled?(feature_name()) :: boolean()
  def enabled?(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:enabled?, name})
  end

  @doc "Returns the full entry for a feature, or `{:error, :not_found}`."
  @spec fetch(feature_name()) :: {:ok, feature_entry()} | {:error, :not_found}
  def fetch(name) when is_binary(name), do: GenServer.call(__MODULE__, {:fetch, name})

  @doc "Returns all registered features sorted by name."
  @spec all() :: [feature_entry()]
  def all, do: GenServer.call(__MODULE__, :all)

  @impl GenServer
  def init(opts) do
    initial = Keyword.get(opts, :features, [])
    entries = Map.new(initial, fn {name, opts} ->
      entry = build_entry(name, Keyword.get(opts, :enabled, false),
                          Keyword.get(opts, :description, ""), nil)
      {name, entry}
    end)
    {:ok, %{features: entries}}
  end

  @impl GenServer
  def handle_call({:register, name, enabled, description}, _from, state) do
    if Map.has_key?(state.features, name) do
      {:reply, {:error, :already_registered}, state}
    else
      entry = build_entry(name, enabled, description, nil)
      {:reply, :ok, put_in(state, [:features, name], entry)}
    end
  end

  def handle_call({:set_enabled, name, enabled, operator}, _from, state) do
    case Map.get(state.features, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated = %{entry | enabled: enabled, modified_by: operator, modified_at: DateTime.utc_now()}
        Logger.info("[FeatureRegistry] #{name} #{if enabled, do: "enabled", else: "disabled"} by #{operator}")
        {:reply, :ok, put_in(state, [:features, name], updated)}
    end
  end

  def handle_call({:enabled?, name}, _from, state) do
    result = state.features |> Map.get(name, %{enabled: false}) |> Map.get(:enabled, false)
    {:reply, result, state}
  end

  def handle_call({:fetch, name}, _from, state) do
    result = case Map.get(state.features, name) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    sorted = state.features |> Map.values() |> Enum.sort_by(& &1.name)
    {:reply, sorted, state}
  end

  defp build_entry(name, enabled, description, operator) do
    %{name: name, enabled: enabled, description: description,
      modified_by: operator, modified_at: DateTime.utc_now()}
  end
end
```
