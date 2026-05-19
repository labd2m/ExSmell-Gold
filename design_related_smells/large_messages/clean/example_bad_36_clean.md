```elixir
defmodule EventStore.EventMetadata do
  defstruct [:causation_id, :correlation_id, :user_id, :ip, :user_agent, :timestamp]

  @type t :: %__MODULE__{
          causation_id: String.t(),
          correlation_id: String.t(),
          user_id: String.t() | nil,
          ip: String.t() | nil,
          user_agent: String.t() | nil,
          timestamp: DateTime.t()
        }
end

defmodule EventStore.DomainEvent do
  @enforce_keys [:id, :stream_id, :type, :version, :payload, :metadata, :inserted_at]
  defstruct [:id, :stream_id, :type, :version, :payload, :metadata, :inserted_at, :global_position]

  @type t :: %__MODULE__{
          id: String.t(),
          stream_id: String.t(),
          type: String.t(),
          version: pos_integer(),
          payload: map(),
          metadata: EventStore.EventMetadata.t(),
          inserted_at: DateTime.t(),
          global_position: pos_integer()
        }
end

defmodule EventStore.StreamReader do
  @moduledoc "Reads all events from a given stream."

  @spec read_all(String.t()) :: [EventStore.DomainEvent.t()]
  def read_all(stream_id) do
    now = DateTime.utc_now()

    event_types = [
      "OrderPlaced",
      "OrderItemAdded",
      "OrderItemRemoved",
      "OrderConfirmed",
      "OrderShipped",
      "OrderDelivered",
      "OrderCancelled",
      "PaymentAuthorised",
      "PaymentCaptured",
      "PaymentRefunded",
      "ShippingAddressUpdated",
      "CustomerNoteAdded"
    ]

    Enum.map(1..60_000, fn n ->
      event_type = Enum.random(event_types)

      payload =
        case event_type do
          "OrderPlaced" ->
            %{
              order_id: stream_id,
              customer_id: "cust_#{rem(n, 100_000)}",
              items:
                Enum.map(1..8, fn i ->
                  %{
                    sku: "SKU-#{rem(n * i, 50_000)}",
                    qty: :rand.uniform(10),
                    unit_price: Float.round(:rand.uniform() * 500, 2),
                    name: "Product #{rem(n * i, 50_000)}"
                  }
                end),
              shipping_address: %{
                street: "#{rem(n, 9999) + 1} Main St",
                city: "City #{rem(n, 500)}",
                state: "ST",
                zip: "#{rem(n, 90000) + 10000}",
                country: "US"
              },
              currency: "USD",
              discount_codes: ["DISC#{rem(n, 50)}"]
            }

          "PaymentAuthorised" ->
            %{
              payment_id: "pay_#{n}",
              amount: Float.round(:rand.uniform() * 2000, 2),
              currency: "USD",
              gateway: "stripe",
              gateway_response: %{
                charge_id: "ch_#{n}_#{:rand.uniform(999_999)}",
                risk_level: Enum.random(["normal", "elevated"]),
                three_d_secure: rem(n, 4) == 0
              }
            }

          _ ->
            %{
              event_ref: "ref_#{n}",
              data: %{field_1: "val_#{rem(n, 1000)}", field_2: :rand.uniform(100)},
              reason: "Automated event #{n}"
            }
        end

      %EventStore.DomainEvent{
        id: "evt_#{stream_id}_#{n}",
        stream_id: stream_id,
        type: event_type,
        version: n,
        global_position: n * 3 + :rand.uniform(5),
        inserted_at: DateTime.add(now, -:rand.uniform(365) * 86_400, :second),
        payload: payload,
        metadata: %EventStore.EventMetadata{
          causation_id: "cmd_#{n}",
          correlation_id: "corr_#{rem(n, 10_000)}",
          user_id: if(rem(n, 10) != 0, do: "usr_#{rem(n, 50_000)}"),
          ip: "203.#{rem(n, 255)}.#{rem(n * 3, 255)}.#{rem(n * 7, 255)}",
          user_agent: "App/3.0 (iOS 17)",
          timestamp: DateTime.add(now, -:rand.uniform(365) * 86_400, :second)
        }
      }
    end)
  end
end

defmodule EventStore.ProjectionWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:replay_events, projection_name, events}, state) do
    {:noreply, Map.put(state, projection_name, length(events))}
  end
end

defmodule EventStore.ProjectionBuilder do
  @moduledoc """
  Handles full projection rebuilds by loading the complete event stream
  and replaying all events through the projection worker.
  """

  require Logger

  @spec rebuild_projection(pid(), String.t()) :: :ok
  def rebuild_projection(projection_pid, stream_id) do
    projection_name = "projection:#{stream_id}"

    Logger.info("Starting full rebuild of projection '#{projection_name}'...")

    events = EventStore.StreamReader.read_all(stream_id)

    Logger.info(
      "Loaded #{length(events)} events for stream '#{stream_id}'. " <>
        "Sending to projection worker for replay..."
    )

    send(projection_pid, {:replay_events, projection_name, events})

    Logger.info("Projection rebuild initiated for '#{projection_name}'.")
    :ok
  end
end
```
