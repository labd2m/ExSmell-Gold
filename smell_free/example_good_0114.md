```elixir
defmodule Pubsub.MessageRouter do
  @moduledoc """
  Routes inbound PubSub messages to registered handler modules. Handlers
  subscribe to one or more topic patterns. The router matches incoming
  messages against registered patterns in priority order, invoking only
  the first matching handler. All routing logic is encapsulated within
  this module so handler modules remain unaware of each other.
  """

  use GenServer

  @type topic :: String.t()
  @type message :: map()
  @type handler :: module()
  @type registration :: %{pattern: String.t(), handler: handler(), priority: non_neg_integer()}

  @doc "Starts the message router registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a handler for the given topic pattern. Lower priority values
  are matched first. Pattern supports a trailing `*` wildcard.
  """
  @spec register(String.t(), handler(), priority: non_neg_integer()) :: :ok
  def register(pattern, handler, opts \\ [])
      when is_binary(pattern) and is_atom(handler) do
    priority = Keyword.get(opts, :priority, 100)
    GenServer.call(__MODULE__, {:register, pattern, handler, priority})
  end

  @doc "Dispatches a message to the highest-priority matching handler."
  @spec dispatch(topic(), message()) :: :ok | {:error, :no_handler}
  def dispatch(topic, message) when is_binary(topic) and is_map(message) do
    GenServer.call(__MODULE__, {:dispatch, topic, message})
  end

  @doc "Lists all current registrations sorted by priority."
  @spec list_registrations() :: [registration()]
  def list_registrations do
    GenServer.call(__MODULE__, :list_registrations)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{registrations: []}}

  @impl GenServer
  def handle_call({:register, pattern, handler, priority}, _from, state) do
    reg = %{pattern: pattern, handler: handler, priority: priority}
    sorted = Enum.sort_by([reg | state.registrations], & &1.priority)
    {:reply, :ok, %{state | registrations: sorted}}
  end

  def handle_call({:dispatch, topic, message}, _from, state) do
    result =
      state.registrations
      |> Enum.find(fn reg -> topic_matches?(reg.pattern, topic) end)
      |> invoke_handler(topic, message)

    {:reply, result, state}
  end

  def handle_call(:list_registrations, _from, state) do
    {:reply, state.registrations, state}
  end

  defp topic_matches?(pattern, topic) do
    if String.ends_with?(pattern, "*") do
      prefix = String.trim_trailing(pattern, "*")
      String.starts_with?(topic, prefix)
    else
      pattern == topic
    end
  end

  defp invoke_handler(nil, _topic, _message), do: {:error, :no_handler}

  defp invoke_handler(%{handler: handler}, topic, message) do
    handler.handle_message(topic, message)
    :ok
  rescue
    _err -> {:error, :no_handler}
  end
end
```
