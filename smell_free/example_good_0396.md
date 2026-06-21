```elixir
defmodule Pipeline.EventProducer do
  @moduledoc """
  A `GenStage` producer that emits domain events pulled from a PostgreSQL
  queue table. It uses demand-driven polling so events are fetched only
  when downstream consumers are ready to process them, providing natural
  back-pressure without an external message broker.
  The producer marks events as `:processing` before emitting them and
  relies on consumer acknowledgement to transition them to `:done`.
  """

  use GenStage

  alias Pipeline.{EventQueue, Repo}

  @poll_interval_ms 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenStage
  def init(_opts) do
    {:producer, %{pending_demand: 0}}
  end

  @impl GenStage
  def handle_demand(demand, %{pending_demand: buffered} = state) when demand > 0 do
    total_demand = demand + buffered
    {events, remaining} = fetch_events(total_demand)

    if events == [] do
      schedule_poll()
      {:noreply, [], %{state | pending_demand: total_demand}}
    else
      {:noreply, events, %{state | pending_demand: remaining}}
    end
  end

  @impl GenStage
  def handle_info(:poll, %{pending_demand: demand} = state) when demand > 0 do
    {events, remaining} = fetch_events(demand)

    if events == [] do
      schedule_poll()
      {:noreply, [], %{state | pending_demand: demand}}
    else
      {:noreply, events, %{state | pending_demand: remaining}}
    end
  end

  def handle_info(:poll, state), do: {:noreply, [], state}

  defp fetch_events(count) do
    events = EventQueue.claim(count)
    remaining = max(0, count - length(events))
    {events, remaining}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end

defmodule Pipeline.EventConsumer do
  @moduledoc """
  A `GenStage` consumer that processes domain events emitted by
  `Pipeline.EventProducer`. Each event is dispatched to the appropriate
  handler module based on its type. Successful processing acknowledges
  the event back to the queue; failures mark it for retry with an
  incremented attempt counter and an exponential delay.
  Consumer concurrency is controlled by the `:concurrency` start option.
  """

  use GenStage

  alias Pipeline.EventQueue

  require Logger

  @handlers %{
    "user.registered" => Pipeline.Handlers.UserRegistered,
    "order.placed" => Pipeline.Handlers.OrderPlaced,
    "payment.failed" => Pipeline.Handlers.PaymentFailed
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl GenStage
  def init(opts) do
    max_demand = Keyword.get(opts, :max_demand, 10)
    min_demand = Keyword.get(opts, :min_demand, 5)

    {:consumer, %{},
     subscribe_to: [{Pipeline.EventProducer, max_demand: max_demand, min_demand: min_demand}]}
  end

  @impl GenStage
  def handle_events(events, _from, state) do
    Enum.each(events, &process_event/1)
    {:noreply, [], state}
  end

  defp process_event(event) do
    case Map.get(@handlers, event.type) do
      nil ->
        Logger.warning("No handler registered for event type", event_type: event.type, event_id: event.id)
        EventQueue.acknowledge(event.id)

      handler ->
        case handler.handle(event.payload) do
          :ok ->
            EventQueue.acknowledge(event.id)

          {:error, reason} ->
            Logger.warning("Event processing failed",
              event_id: event.id,
              event_type: event.type,
              attempt: event.attempt,
              reason: inspect(reason)
            )
            EventQueue.reschedule(event.id, backoff_ms(event.attempt))
        end
    end
  rescue
    exception ->
      Logger.error("Unhandled exception in event consumer",
        event_id: event.id,
        exception: Exception.message(exception),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )
      EventQueue.reschedule(event.id, backoff_ms(event.attempt))
  end

  defp backoff_ms(attempt), do: min(trunc(500 * :math.pow(2, attempt)), 30_000)
end

defmodule Pipeline.Supervisor do
  @moduledoc """
  Supervises the event processing pipeline, starting the producer and
  the configured number of consumer processes under a one-for-one strategy.
  """

  use Supervisor

  @consumer_count 4

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    consumer_count = Keyword.get(opts, :consumer_count, @consumer_count)

    consumers =
      Enum.map(1..consumer_count, fn i ->
        Supervisor.child_spec({Pipeline.EventConsumer, []}, id: {Pipeline.EventConsumer, i})
      end)

    children = [Pipeline.EventProducer | consumers]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
