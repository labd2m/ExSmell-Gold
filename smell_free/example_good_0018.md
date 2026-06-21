# File: `example_good_18.md`

```elixir
defprotocol Encoding.Serializable do
  @moduledoc """
  Protocol for converting domain structs into portable wire representations.

  Implementing modules define how their data is encoded for external
  consumption (e.g. JSON API responses, message queues, audit logs).
  The protocol keeps encoding logic colocated with the types that own
  the data rather than scattered across adapter modules.
  """

  @doc """
  Serializes `value` into a plain map suitable for JSON encoding.

  All keys in the returned map must be strings. Nested structs that
  implement `Serializable` should be serialized recursively.
  """
  @spec to_wire(t()) :: map()
  def to_wire(value)

  @doc """
  Returns the resource type identifier for `value`, used as the
  primary type discriminator in API envelopes and message headers.
  """
  @spec resource_type(t()) :: String.t()
  def resource_type(value)
end

defimpl Encoding.Serializable, for: Accounts.User do
  @doc false
  def to_wire(user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "display_name" => user.display_name,
      "role" => Atom.to_string(user.role),
      "verified" => user.email_verified,
      "created_at" => DateTime.to_iso8601(user.inserted_at)
    }
  end

  @doc false
  def resource_type(_user), do: "user"
end

defimpl Encoding.Serializable, for: Billing.Invoice do
  @doc false
  def to_wire(invoice) do
    %{
      "id" => invoice.id,
      "number" => invoice.number,
      "status" => Atom.to_string(invoice.status),
      "amount_cents" => invoice.amount_cents,
      "currency" => invoice.currency,
      "issued_at" => DateTime.to_iso8601(invoice.issued_at),
      "due_at" => date_or_nil(invoice.due_at),
      "line_items" => Enum.map(invoice.line_items, &serialize_line_item/1)
    }
  end

  @doc false
  def resource_type(_invoice), do: "invoice"

  defp serialize_line_item(item) do
    %{
      "description" => item.description,
      "quantity" => item.quantity,
      "unit_price_cents" => item.unit_price_cents,
      "subtotal_cents" => item.quantity * item.unit_price_cents
    }
  end

  defp date_or_nil(nil), do: nil
  defp date_or_nil(dt), do: DateTime.to_iso8601(dt)
end

defimpl Encoding.Serializable, for: Shipping.Shipment do
  @doc false
  def to_wire(shipment) do
    %{
      "id" => shipment.id,
      "tracking_number" => shipment.tracking_number,
      "carrier" => shipment.carrier,
      "status" => Atom.to_string(shipment.status),
      "origin" => serialize_address(shipment.origin),
      "destination" => serialize_address(shipment.destination),
      "estimated_delivery" => date_or_nil(shipment.estimated_delivery),
      "shipped_at" => datetime_or_nil(shipment.shipped_at)
    }
  end

  @doc false
  def resource_type(_shipment), do: "shipment"

  defp serialize_address(address) do
    %{
      "line1" => address.line1,
      "line2" => address.line2,
      "city" => address.city,
      "state" => address.state,
      "postal_code" => address.postal_code,
      "country_code" => address.country_code
    }
  end

  defp date_or_nil(nil), do: nil
  defp date_or_nil(date), do: Date.to_iso8601(date)

  defp datetime_or_nil(nil), do: nil
  defp datetime_or_nil(dt), do: DateTime.to_iso8601(dt)
end

defmodule Encoding.Serializable.Helpers do
  @moduledoc """
  Utility functions for working with the `Serializable` protocol.
  """

  alias Encoding.Serializable

  @doc """
  Wraps a serialized value in a standard API envelope containing
  the resource type and the wire-format data.
  """
  @spec to_envelope(Serializable.t()) :: map()
  def to_envelope(value) do
    %{
      "type" => Serializable.resource_type(value),
      "data" => Serializable.to_wire(value)
    }
  end

  @doc """
  Serializes a list of values into an API collection envelope.
  """
  @spec to_collection_envelope([Serializable.t()]) :: map()
  def to_collection_envelope(values) when is_list(values) do
    items = Enum.map(values, &Serializable.to_wire/1)
    type = collection_type(values)
    %{"type" => type, "data" => items, "count" => length(items)}
  end

  defp collection_type([]), do: "collection"
  defp collection_type([first | _rest]), do: "#{Serializable.resource_type(first)}_collection"
end
```
