```elixir
defprotocol Events.Serializable do
  @moduledoc """
  Protocol for converting domain event structs into wire-format maps
  with string keys. Implementations must return data that is directly
  passable to a JSON encoder without further transformation.
  """

  @doc "Converts an event struct into a string-keyed map for serialization."
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(event)

  @doc "Returns the event type string used in the message envelope."
  @spec event_type(t()) :: String.t()
  def event_type(event)
end

defmodule Events.OrderPlaced do
  @moduledoc "Domain event emitted when a customer successfully places an order."

  @enforce_keys [:order_id, :customer_id, :total_cents, :placed_at]
  defstruct [:order_id, :customer_id, :total_cents, :placed_at, line_items: []]

  @type t :: %__MODULE__{
          order_id: String.t(),
          customer_id: String.t(),
          total_cents: pos_integer(),
          placed_at: DateTime.t(),
          line_items: [map()]
        }

  defimpl Events.Serializable do
    def to_wire(%Events.OrderPlaced{} = e) do
      %{
        "order_id" => e.order_id,
        "customer_id" => e.customer_id,
        "total_cents" => e.total_cents,
        "placed_at" => DateTime.to_iso8601(e.placed_at),
        "line_items" => e.line_items
      }
    end

    def event_type(_), do: "order.placed"
  end
end

defmodule Events.PaymentFailed do
  @moduledoc "Domain event emitted when a payment attempt is declined or errors."

  @enforce_keys [:order_id, :failure_code, :occurred_at]
  defstruct [:order_id, :failure_code, :occurred_at, gateway_ref: nil]

  @type failure_code :: :insufficient_funds | :card_declined | :gateway_error
  @type t :: %__MODULE__{
          order_id: String.t(),
          failure_code: failure_code(),
          occurred_at: DateTime.t(),
          gateway_ref: String.t() | nil
        }

  defimpl Events.Serializable do
    def to_wire(%Events.PaymentFailed{} = e) do
      %{
        "order_id" => e.order_id,
        "failure_code" => Atom.to_string(e.failure_code),
        "occurred_at" => DateTime.to_iso8601(e.occurred_at),
        "gateway_ref" => e.gateway_ref
      }
    end

    def event_type(_), do: "payment.failed"
  end
end

defmodule Events.Publisher do
  @moduledoc """
  Wraps domain events in a typed envelope and broadcasts them to the
  configured PubSub topic. Any struct implementing `Events.Serializable`
  can be published through this module.
  """

  @pubsub MyApp.PubSub
  @topic "domain:events"

  @doc """
  Publishes a domain event, wrapping it in a standard envelope with the
  event type, serialized payload, and UTC publication timestamp.
  """
  @spec publish(Events.Serializable.t()) :: :ok
  def publish(event) do
    envelope = %{
      "type" => Events.Serializable.event_type(event),
      "payload" => Events.Serializable.to_wire(event),
      "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:domain_event, envelope})
  end
end
```
