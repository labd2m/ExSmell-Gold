```elixir
defmodule Feeds.SubscriptionSupervisor do
  @moduledoc """
  Manages per-user live feed workers under a DynamicSupervisor. Each user's
  subscription runs in an isolated GenServer process. Workers are started
  on demand and terminated when the subscription is cancelled.
  """

  use DynamicSupervisor

  alias Feeds.SubscriptionWorker

  @type user_id :: String.t()
  @type feed_config :: %{topics: [String.t()], buffer_size: pos_integer()}

  @doc "Starts the subscription supervisor linked to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a feed worker for `user_id` with the provided `config`. Returns
  `{:error, :already_subscribed}` if the user already has an active worker.
  """
  @spec subscribe(user_id(), feed_config()) :: {:ok, pid()} | {:error, :already_subscribed}
  def subscribe(user_id, %{topics: _, buffer_size: _} = config) when is_binary(user_id) do
    spec = {SubscriptionWorker, %{user_id: user_id, config: config}}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_subscribed}
      {:error, _} -> {:error, :already_subscribed}
    end
  end

  @doc "Terminates the feed worker for `user_id`. Idempotent."
  @spec unsubscribe(user_id()) :: :ok
  def unsubscribe(user_id) when is_binary(user_id) do
    case Registry.lookup(Feeds.Registry, user_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end

    :ok
  end

  @doc "Returns true when the user has an active subscription worker."
  @spec subscribed?(user_id()) :: boolean()
  def subscribed?(user_id) when is_binary(user_id) do
    Registry.lookup(Feeds.Registry, user_id) != []
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Feeds.SubscriptionWorker do
  @moduledoc """
  Handles a single user's live feed subscription. Subscribes to configured
  PubSub topics on startup, buffers incoming events up to the configured
  limit, and exposes the buffer via a synchronous drain call.
  """

  use GenServer

  @type state :: %{
          user_id: String.t(),
          topics: [String.t()],
          buffer: [map()],
          buffer_size: pos_integer()
        }

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{user_id: user_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via(user_id))
  end

  @doc "Returns all buffered events and clears the buffer."
  @spec drain(String.t()) :: [map()]
  def drain(user_id) when is_binary(user_id) do
    GenServer.call(via(user_id), :drain)
  end

  @impl GenServer
  def init(%{user_id: user_id, config: %{topics: topics, buffer_size: buffer_size}}) do
    Enum.each(topics, &Phoenix.PubSub.subscribe(MyApp.PubSub, &1))
    {:ok, %{user_id: user_id, topics: topics, buffer: [], buffer_size: buffer_size}}
  end

  @impl GenServer
  def handle_call(:drain, _from, state) do
    {:reply, Enum.reverse(state.buffer), %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info({:domain_event, event}, state) do
    trimmed = [event | state.buffer] |> Enum.take(state.buffer_size)
    {:noreply, %{state | buffer: trimmed}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp via(user_id), do: {:via, Registry, {Feeds.Registry, user_id}}
end
```
