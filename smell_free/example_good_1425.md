```elixir
defmodule Shipping.Tracking.EventLog do
  @moduledoc """
  Append-only event log for shipment tracking lifecycle events.
  Events are immutable once written and stored with monotonic timestamps.
  """

  alias Shipping.Tracking.{Event, EventLog}

  @type t :: %__MODULE__{
          shipment_id: String.t(),
          events: [Event.t()]
        }

  defstruct shipment_id: nil, events: []

  @doc """
  Creates a new, empty event log for the given shipment.
  """
  @spec new(String.t()) :: t()
  def new(shipment_id) when is_binary(shipment_id) and shipment_id != "" do
    %__MODULE__{shipment_id: shipment_id, events: []}
  end

  @doc """
  Appends a new tracking event to the log.
  Returns `{:ok, updated_log}` or `{:error, reason}`.
  """
  @spec append(t(), atom(), map()) :: {:ok, t()} | {:error, String.t()}
  def append(%EventLog{} = log, event_type, payload)
      when is_atom(event_type) and is_map(payload) do
    case Event.new(event_type, payload) do
      {:ok, event} -> {:ok, %{log | events: log.events ++ [event]}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns the most recent event from the log, or `{:error, :empty}`.
  """
  @spec latest_event(t()) :: {:ok, Event.t()} | {:error, :empty}
  def latest_event(%EventLog{events: []}), do: {:error, :empty}
  def latest_event(%EventLog{events: events}), do: {:ok, List.last(events)}

  @doc """
  Returns all events matching the given type.
  """
  @spec events_by_type(t(), atom()) :: [Event.t()]
  def events_by_type(%EventLog{events: events}, type) when is_atom(type) do
    Enum.filter(events, fn %Event{type: t} -> t == type end)
  end

  @doc """
  Returns the total number of events in the log.
  """
  @spec event_count(t()) :: non_neg_integer()
  def event_count(%EventLog{events: events}), do: length(events)
end

defmodule Shipping.Tracking.Event do
  @moduledoc """
  An immutable tracking event stamped with a monotonic timestamp.
  """

  @type t :: %__MODULE__{
          type: atom(),
          payload: map(),
          occurred_at: integer()
        }

  defstruct [:type, :payload, :occurred_at]

  @known_types ~w(picked_up in_transit out_for_delivery delivered returned)a

  @doc """
  Creates a new event of the given type with arbitrary payload metadata.
  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec new(atom(), map()) :: {:ok, t()} | {:error, String.t()}
  def new(type, payload) when is_atom(type) and is_map(payload) do
    if type in @known_types do
      {:ok, %__MODULE__{type: type, payload: payload, occurred_at: System.monotonic_time()}}
    else
      {:error, "unknown event type: #{inspect(type)}"}
    end
  end
end
```
