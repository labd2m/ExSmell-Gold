```elixir
defprotocol Analytics.Encodable do
  @moduledoc """
  Converts a domain struct into a flat map suitable for forwarding to
  the analytics ingestion pipeline. Implementing this protocol decouples
  event-schema concerns from business logic and removes the need for
  conditional dispatch across entity types.
  """

  @doc """
  Returns a flat `%{String.t() => term()}` map representing the entity.
  All keys must be strings. Nested maps are not permitted — callers should
  prefix nested concepts with an underscore separator (e.g., `"order_total"`).
  """
  @spec encode(t()) :: %{String.t() => term()}
  def encode(entity)

  @doc """
  Returns the analytics event name associated with this entity, used as
  the `event` field in the ingestion payload (e.g., `"order.completed"`).
  """
  @spec event_name(t()) :: String.t()
  def event_name(entity)
end

defmodule Analytics.Events.OrderCompleted do
  @moduledoc """
  Represents a finalized order event captured at checkout completion.
  """

  @enforce_keys [:order_id, :customer_id, :total_cents, :currency, :item_count, :occurred_at]
  defstruct [:order_id, :customer_id, :total_cents, :currency, :item_count, :occurred_at,
             discount_cents: 0, coupon_code: nil]

  @type t :: %__MODULE__{
          order_id: binary(),
          customer_id: binary(),
          total_cents: pos_integer(),
          currency: binary(),
          item_count: pos_integer(),
          discount_cents: non_neg_integer(),
          coupon_code: binary() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Analytics.Encodable do
    def encode(event) do
      %{
        "order_id" => event.order_id,
        "customer_id" => event.customer_id,
        "order_total_cents" => event.total_cents,
        "order_currency" => event.currency,
        "order_item_count" => event.item_count,
        "order_discount_cents" => event.discount_cents,
        "order_coupon_code" => event.coupon_code,
        "occurred_at" => DateTime.to_iso8601(event.occurred_at)
      }
    end

    def event_name(_event), do: "order.completed"
  end
end

defmodule Analytics.Events.UserRegistered do
  @moduledoc """
  Represents a new user registration event.
  """

  @enforce_keys [:user_id, :email, :plan, :referral_source, :occurred_at]
  defstruct [:user_id, :email, :plan, :referral_source, :occurred_at]

  @type t :: %__MODULE__{
          user_id: binary(),
          email: binary(),
          plan: :free | :pro | :enterprise,
          referral_source: binary() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Analytics.Encodable do
    def encode(event) do
      %{
        "user_id" => event.user_id,
        "user_email_domain" => extract_domain(event.email),
        "user_plan" => Atom.to_string(event.plan),
        "user_referral_source" => event.referral_source,
        "occurred_at" => DateTime.to_iso8601(event.occurred_at)
      }
    end

    def event_name(_event), do: "user.registered"

    defp extract_domain(email) do
      case String.split(email, "@") do
        [_local, domain] -> domain
        _ -> "unknown"
      end
    end
  end
end

defmodule Analytics.Dispatcher do
  @moduledoc """
  Builds and forwards a structured analytics payload for any entity
  that implements the `Analytics.Encodable` protocol.
  """

  @doc """
  Sends the encoded event to the analytics backend.
  Returns `{:ok, event_name}` on success or `{:error, reason}` on failure.
  """
  @spec dispatch(Analytics.Encodable.t()) :: {:ok, String.t()} | {:error, term()}
  def dispatch(entity) do
    event_name = Analytics.Encodable.event_name(entity)
    payload = build_payload(entity, event_name)
    Analytics.Backend.publish(payload)
  end

  defp build_payload(entity, event_name) do
    %{
      "event" => event_name,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "properties" => Analytics.Encodable.encode(entity)
    }
  end
end
```
