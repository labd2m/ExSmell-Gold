```elixir
defprotocol Dataflow.Encodable do
  @moduledoc """
  Protocol defining a contract for encoding domain structs into
  wire-format maps suitable for JSON serialization or external API delivery.
  """

  @doc "Encodes a struct into a plain map with string keys."
  @spec encode(t()) :: map()
  def encode(value)

  @doc "Returns the canonical string type tag for the encoded entity."
  @spec type_tag(t()) :: String.t()
  def type_tag(value)
end

defmodule Dataflow.Event do
  @moduledoc "Represents a domain event emitted by an aggregate."

  @type severity :: :info | :warning | :critical

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          severity: severity(),
          payload: map(),
          emitted_at: DateTime.t()
        }

  defstruct [:id, :name, :severity, :payload, :emitted_at]

  @spec new(String.t(), severity(), map()) :: t()
  def new(name, severity, payload)
      when is_binary(name) and severity in [:info, :warning, :critical] and is_map(payload) do
    %__MODULE__{
      id: Ecto.UUID.generate(),
      name: name,
      severity: severity,
      payload: payload,
      emitted_at: DateTime.utc_now()
    }
  end
end

defmodule Dataflow.Metric do
  @moduledoc "Represents a numeric measurement captured at a point in time."

  @type t :: %__MODULE__{
          name: String.t(),
          value: float(),
          unit: String.t(),
          tags: %{String.t() => String.t()},
          recorded_at: DateTime.t()
        }

  defstruct [:name, :value, :unit, :tags, :recorded_at]

  @spec new(String.t(), float(), String.t(), map()) :: t()
  def new(name, value, unit, tags \\ %{})
      when is_binary(name) and is_float(value) and is_binary(unit) and is_map(tags) do
    %__MODULE__{
      name: name,
      value: value,
      unit: unit,
      tags: tags,
      recorded_at: DateTime.utc_now()
    }
  end
end

defimpl Dataflow.Encodable, for: Dataflow.Event do
  def encode(%Dataflow.Event{} = event) do
    %{
      "id" => event.id,
      "name" => event.name,
      "severity" => Atom.to_string(event.severity),
      "payload" => event.payload,
      "emitted_at" => DateTime.to_iso8601(event.emitted_at)
    }
  end

  def type_tag(_event), do: "event"
end

defimpl Dataflow.Encodable, for: Dataflow.Metric do
  def encode(%Dataflow.Metric{} = metric) do
    %{
      "name" => metric.name,
      "value" => metric.value,
      "unit" => metric.unit,
      "tags" => metric.tags,
      "recorded_at" => DateTime.to_iso8601(metric.recorded_at)
    }
  end

  def type_tag(_metric), do: "metric"
end

defmodule Dataflow.Encoder do
  @moduledoc """
  Wraps any `Dataflow.Encodable` value into a typed envelope map
  ready for downstream transport.
  """

  alias Dataflow.Encodable

  @type envelope :: %{String.t() => term()}

  @spec wrap(Encodable.t()) :: envelope()
  def wrap(value) do
    %{
      "type" => Encodable.type_tag(value),
      "data" => Encodable.encode(value),
      "schema_version" => "1.0"
    }
  end

  @spec wrap_all([Encodable.t()]) :: [envelope()]
  def wrap_all(values) when is_list(values) do
    Enum.map(values, &wrap/1)
  end
end
```
