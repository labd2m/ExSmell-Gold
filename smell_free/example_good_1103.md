```elixir
defmodule Serializable do
  @moduledoc """
  Protocol for converting domain structs to and from external wire formats.
  Implementations must produce and consume plain maps with string keys,
  suitable for JSON encoding.
  """

  @type wire_map :: %{required(String.t()) => term()}

  @callback to_wire(struct()) :: wire_map()
  @callback from_wire(wire_map()) :: {:ok, struct()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Serializable
    end
  end
end

defmodule Notifications.Event do
  @moduledoc "Domain struct representing a notification event to be delivered."

  @type t :: %__MODULE__{
          id: String.t(),
          recipient_id: String.t(),
          channel: :email | :sms | :push,
          template: String.t(),
          variables: map(),
          scheduled_at: DateTime.t() | nil
        }

  defstruct [:id, :recipient_id, :channel, :template, :variables, :scheduled_at]
end

defmodule Notifications.Event.Serializer do
  @moduledoc "Wire serialization for `Notifications.Event` structs."

  use Serializable

  alias Notifications.Event

  @impl Serializable
  def to_wire(%Event{} = event) do
    %{
      "id" => event.id,
      "recipient_id" => event.recipient_id,
      "channel" => Atom.to_string(event.channel),
      "template" => event.template,
      "variables" => event.variables,
      "scheduled_at" => encode_datetime(event.scheduled_at)
    }
  end

  @impl Serializable
  def from_wire(%{"id" => id, "recipient_id" => rid, "channel" => ch,
                  "template" => tpl, "variables" => vars} = wire)
      when is_binary(id) and is_binary(rid) and is_binary(ch) and is_binary(tpl) and is_map(vars) do
    with {:ok, channel} <- parse_channel(ch),
         {:ok, scheduled_at} <- parse_optional_datetime(Map.get(wire, "scheduled_at")) do
      {:ok, %Event{
        id: id,
        recipient_id: rid,
        channel: channel,
        template: tpl,
        variables: vars,
        scheduled_at: scheduled_at
      }}
    end
  end

  def from_wire(_wire), do: {:error, :invalid_wire_format}

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_channel("email"), do: {:ok, :email}
  defp parse_channel("sms"), do: {:ok, :sms}
  defp parse_channel("push"), do: {:ok, :push}
  defp parse_channel(other), do: {:error, {:unknown_channel, other}}

  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:invalid_datetime, reason}}
    end
  end
end
```
