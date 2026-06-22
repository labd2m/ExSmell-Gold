```elixir
defmodule Comms.LiveChatSupervisor do
  @moduledoc """
  Manages live chat sessions between customers and support agents. Each
  session runs in its own GenServer, holding the message history and
  participant state. Sessions expire after an inactivity timeout and are
  started on demand under a DynamicSupervisor so the supervision tree
  scales naturally with concurrent chat volume.
  """

  use DynamicSupervisor

  alias Comms.ChatSession

  @type session_id :: String.t()

  @doc "Starts the live chat supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Opens a new chat session between `customer_id` and `agent_id`. Returns
  the session ID or `{:error, :already_open}` when a session is
  already active for the customer.
  """
  @spec open(String.t(), String.t()) :: {:ok, session_id()} | {:error, :already_open}
  def open(customer_id, agent_id) when is_binary(customer_id) and is_binary(agent_id) do
    session_id = generate_id()
    opts = [session_id: session_id, customer_id: customer_id, agent_id: agent_id]

    case DynamicSupervisor.start_child(__MODULE__, {ChatSession, opts}) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, {:already_started, _}} -> {:error, :already_open}
      {:error, _} -> {:error, :already_open}
    end
  end

  @doc "Returns true when an active chat session exists for `session_id`."
  @spec active?(session_id()) :: boolean()
  def active?(session_id) when is_binary(session_id) do
    Registry.lookup(Comms.ChatRegistry, session_id) != []
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

defmodule Comms.ChatSession do
  @moduledoc """
  Manages a single live chat session. Records messages from both parties,
  enforces participant validation, and broadcasts each new message on
  PubSub. Terminates normally after an inactivity timeout.
  """

  use GenServer

  require Logger

  @type message :: %{sender_id: String.t(), body: String.t(), sent_at: DateTime.t()}
  @inactivity_timeout_ms :timer.minutes(20)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc "Sends a message from `sender_id` in session `session_id`."
  @spec send_message(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_a_participant | :session_not_found}
  def send_message(session_id, sender_id, body)
      when is_binary(session_id) and is_binary(sender_id) and is_binary(body) do
    case Registry.lookup(Comms.ChatRegistry, session_id) do
      [] -> {:error, :session_not_found}
      [{pid, _}] -> GenServer.call(pid, {:send_message, sender_id, body})
    end
  end

  @doc "Returns the full message history for `session_id`."
  @spec history(String.t()) :: [message()]
  def history(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :history)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      customer_id: Keyword.fetch!(opts, :customer_id),
      agent_id: Keyword.fetch!(opts, :agent_id),
      messages: []
    }

    {:ok, state, @inactivity_timeout_ms}
  end

  @impl GenServer
  def handle_call({:send_message, sender_id, body}, _from, state) do
    if sender_id in [state.customer_id, state.agent_id] do
      msg = %{sender_id: sender_id, body: body, sent_at: DateTime.utc_now()}
      broadcast(state.session_id, msg)
      {:reply, :ok, %{state | messages: state.messages ++ [msg]}, @inactivity_timeout_ms}
    else
      {:reply, {:error, :not_a_participant}, state, @inactivity_timeout_ms}
    end
  end

  def handle_call(:history, _from, state) do
    {:reply, state.messages, state, @inactivity_timeout_ms}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.info("[ChatSession] #{state.session_id} expired due to inactivity")
    {:stop, :normal, state}
  end

  defp broadcast(session_id, msg) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "chat:#{session_id}", {:new_message, msg})
  end

  defp via(session_id), do: {:via, Registry, {Comms.ChatRegistry, session_id}}
end
```
