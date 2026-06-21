# File: `example_good_100.md`

```elixir
defmodule Events.Dispatcher do
  @moduledoc """
  In-process publish-subscribe dispatcher for domain events.

  Modules subscribe to named event types with a handler function.
  When an event is dispatched, all registered handlers for that type
  are invoked concurrently in supervised Tasks, preventing a slow
  handler from blocking the dispatch loop or other subscribers.

  Subscriptions are process-local and cleaned up automatically when
  the subscribing process exits.
  """

  use GenServer

  require Logger

  @type event_type :: atom()
  @type handler_fn :: (map() -> :ok | {:error, term()})
  @type subscription_id :: reference()

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Subscribes `handler_fn` to all events of `event_type`.

  The handler is automatically removed when the calling process exits.
  Returns a `subscription_id` that can be passed to `unsubscribe/1`.
  """
  @spec subscribe(event_type(), handler_fn()) :: {:ok, subscription_id()}
  def subscribe(event_type, handler_fn)
      when is_atom(event_type) and is_function(handler_fn, 1) do
    GenServer.call(__MODULE__, {:subscribe, event_type, handler_fn, self()})
  end

  @doc """
  Removes the subscription identified by `subscription_id`.
  """
  @spec unsubscribe(subscription_id()) :: :ok
  def unsubscribe(subscription_id) when is_reference(subscription_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Dispatches `event` to all handlers subscribed to its type.

  `event` must contain a `:type` key with an atom value. Dispatch is
  asynchronous; returns `:ok` immediately without waiting for handlers.
  """
  @spec dispatch(%{required(:type) => event_type()}) :: :ok | {:error, :missing_type}
  def dispatch(%{type: type} = event) when is_atom(type) do
    GenServer.cast(__MODULE__, {:dispatch, event})
  end

  def dispatch(_event), do: {:error, :missing_type}

  @doc """
  Returns the count of active subscriptions for a given event type.
  """
  @spec subscription_count(event_type()) :: non_neg_integer()
  def subscription_count(event_type) when is_atom(event_type) do
    GenServer.call(__MODULE__, {:subscription_count, event_type})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{subscriptions: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, event_type, handler_fn, subscriber_pid}, _from, state) do
    subscription_id = make_ref()
    _ref = Process.monitor(subscriber_pid)

    entry = %{
      id: subscription_id,
      event_type: event_type,
      handler: handler_fn,
      pid: subscriber_pid
    }

    new_state = put_in(state, [:subscriptions, subscription_id], entry)
    {:reply, {:ok, subscription_id}, new_state}
  end

  @impl GenServer
  def handle_call({:subscription_count, event_type}, _from, state) do
    count =
      state.subscriptions
      |> Map.values()
      |> Enum.count(&(&1.event_type == event_type))

    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, subscription_id}, state) do
    {:noreply, update_in(state, [:subscriptions], &Map.delete(&1, subscription_id))}
  end

  @impl GenServer
  def handle_cast({:dispatch, %{type: type} = event}, state) do
    state.subscriptions
    |> Map.values()
    |> Enum.filter(&(&1.event_type == type))
    |> Enum.each(&invoke_handler(&1, event))

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    remaining =
      Map.reject(state.subscriptions, fn {_id, entry} -> entry.pid == pid end)

    {:noreply, %{state | subscriptions: remaining}}
  end

  defp invoke_handler(%{id: id, handler: handler_fn, event_type: type}, event) do
    Task.Supervisor.start_child(Events.TaskSupervisor, fn ->
      case handler_fn.(event) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Handler #{inspect(id)} for #{type} returned error: #{inspect(reason)}")
      end
    end)
  end
end
```
