```elixir
defmodule Config.Loader do
  @moduledoc """
  Loads application configuration from environment variables at runtime
  and broadcasts change events when values are updated via a hot-reload.

  Values are coerced to their declared types when read. Subscribers receive
  `{:config_changed, key, old_value, new_value}` messages whenever a reload
  detects that a value has changed, enabling dependent processes to react
  without polling.
  """

  use GenServer

  @type field_type :: :string | :integer | :boolean | :float

  @type field :: %{
          required(:env_var) => String.t(),
          required(:type) => field_type(),
          optional(:default) => term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get(atom()) :: {:ok, term()} | {:error, :not_found}
  def get(key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @spec get!(atom()) :: term()
  def get!(key) do
    case get(key) do
      {:ok, value} -> value
      {:error, :not_found} -> raise "Config key #{key} not found"
    end
  end

  @spec reload() :: %{changed: [atom()], unchanged: [atom()]}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end

  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  @impl GenServer
  def init(opts) do
    schema = Keyword.fetch!(opts, :schema)
    values = load_all(schema)
    {:ok, %{schema: schema, values: values, subscribers: []}}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.fetch(state.values, key), state}
  end

  def handle_call(:reload, _from, state) do
    new_values = load_all(state.schema)
    changed = for {key, new_val} <- new_values, Map.get(state.values, key) != new_val, do: key

    Enum.each(changed, fn key ->
      old = Map.get(state.values, key)
      new = Map.get(new_values, key)
      Enum.each(state.subscribers, &send(&1, {:config_changed, key, old, new}))
    end)

    unchanged = Map.keys(new_values) -- changed
    {:reply, %{changed: changed, unchanged: unchanged}, %{state | values: new_values}}
  end

  @impl GenServer
  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  defp load_all(schema) do
    Map.new(schema, fn {key, spec} ->
      value = read_env(spec.env_var, spec.type, Map.get(spec, :default))
      {key, value}
    end)
  end

  defp read_env(env_var, type, default) do
    case System.get_env(env_var) do
      nil -> default
      raw -> coerce(raw, type, default)
    end
  end

  defp coerce(raw, :string, _default), do: raw
  defp coerce(raw, :integer, default) do
    case Integer.parse(raw) do
      {n, ""} -> n
      _ -> default
    end
  end
  defp coerce(raw, :float, default) do
    case Float.parse(raw) do
      {f, ""} -> f
      _ -> default
    end
  end
  defp coerce("true", :boolean, _), do: true
  defp coerce("false", :boolean, _), do: false
  defp coerce(_, :boolean, default), do: default
end
```
