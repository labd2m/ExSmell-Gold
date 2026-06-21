```elixir
defmodule Events.Bus do
  @moduledoc """
  A typed domain event bus that validates event payloads against registered
  schemas before broadcasting. Publishers declare the shape of their events
  at startup; any attempt to publish a malformed event is rejected with a
  descriptive error rather than silently delivering corrupt data to subscribers.
  Delivery is async per subscriber so a slow handler never stalls the publisher.
  """

  use GenServer

  require Logger

  @type event_type :: binary()
  @type schema :: %{required(atom()) => module()}
  @type handler :: (map() -> :ok | {:error, term()})

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a schema for `event_type`. The schema is a map of
  `field_name => type_validator_module` pairs. Must be called before
  any `publish/2` calls for that event type.
  """
  @spec register_schema(event_type(), schema()) :: :ok
  def register_schema(event_type, schema)
      when is_binary(event_type) and is_map(schema) do
    GenServer.call(__MODULE__, {:register_schema, event_type, schema})
  end

  @doc """
  Subscribes `handler` to events of `event_type`. The handler is a
  one-arity function invoked asynchronously for each matching event.
  Returns `{:ok, subscription_id}`.
  """
  @spec subscribe(event_type(), handler()) :: {:ok, binary()}
  def subscribe(event_type, handler)
      when is_binary(event_type) and is_function(handler, 1) do
    GenServer.call(__MODULE__, {:subscribe, event_type, handler})
  end

  @doc """
  Cancels the subscription identified by `subscription_id`.
  """
  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(subscription_id) when is_binary(subscription_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Validates `payload` against the registered schema for `event_type` and,
  if valid, delivers it asynchronously to all subscribers.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec publish(event_type(), map()) :: :ok | {:error, term()}
  def publish(event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    GenServer.call(__MODULE__, {:publish, event_type, payload})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok, %{schemas: %{}, subscriptions: %{}}}
  end

  @impl GenServer
  def handle_call({:register_schema, event_type, schema}, _from, state) do
    {:reply, :ok, put_in(state, [:schemas, event_type], schema)}
  end

  def handle_call({:subscribe, event_type, handler}, _from, state) do
    id = generate_id()
    entry = %{event_type: event_type, handler: handler}
    new_state = put_in(state, [:subscriptions, id], entry)
    {:reply, {:ok, id}, new_state}
  end

  def handle_call({:publish, event_type, payload}, _from, state) do
    case validate_payload(payload, Map.get(state.schemas, event_type)) do
      :ok ->
        dispatch(event_type, payload, state.subscriptions)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:validation_failed, reason}}, state}
    end
  end

  @impl GenServer
  def handle_cast({:unsubscribe, id}, state) do
    {:noreply, update_in(state, [:subscriptions], &Map.delete(&1, id))}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_payload(_payload, nil), do: :ok

  defp validate_payload(payload, schema) do
    errors =
      Enum.flat_map(schema, fn {field, type_mod} ->
        value = Map.get(payload, field)

        cond do
          is_nil(value) -> ["#{field}: required field missing"]
          not type_mod.valid?(value) -> ["#{field}: invalid type"]
          true -> []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp dispatch(event_type, payload, subscriptions) do
    subscriptions
    |> Enum.filter(fn {_id, sub} -> sub.event_type == event_type end)
    |> Enum.each(fn {id, %{handler: handler}} ->
      Task.Supervisor.start_child(Events.TaskSupervisor, fn ->
        case handler.(payload) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Event handler failed",
              subscription_id: id,
              event_type: event_type,
              reason: inspect(reason)
            )
        end
      end)
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
