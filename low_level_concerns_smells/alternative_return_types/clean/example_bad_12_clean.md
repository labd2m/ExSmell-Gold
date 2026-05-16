```elixir
defmodule MyApp.Analytics.EventTracker do
  @moduledoc """
  Records domain events for analytics and BI pipelines. Buffers events in
  memory before flushing to the event store. Supports synchronous and
  fire-and-forget modes.
  """

  alias MyApp.Analytics.EventStore
  alias MyApp.Analytics.EventBuffer
  alias MyApp.Analytics.Schema

  defstruct [
    :id, :name, :actor_id, :actor_type,
    :resource_id, :resource_type,
    :metadata, :occurred_at, :session_id
  ]

  @buffer_size 50
  @flush_interval_ms 5_000

  def new(name, actor, resource, metadata \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      name: name,
      actor_id: actor.id,
      actor_type: actor.__struct__,
      resource_id: resource[:id],
      resource_type: resource[:type],
      metadata: metadata,
      occurred_at: DateTime.utc_now(),
      session_id: metadata[:session_id]
    }
  end

  def record(event_attrs, opts \\ []) when is_list(opts) do
    result_mode = Keyword.get(opts, :result, :silent)
    mode = Keyword.get(opts, :mode, :async)
    validate = Keyword.get(opts, :validate, true)

    event = struct(__MODULE__, Map.merge(event_attrs, %{id: generate_id(), occurred_at: DateTime.utc_now()}))

    with :ok <- maybe_validate(event, validate) do
      outcome =
        case mode do
          :sync ->
            EventStore.insert(event)

          :async ->
            EventBuffer.enqueue(event)
            {:ok, event}

          :fire_and_forget ->
            Task.start(fn -> EventStore.insert(event) end)
            {:ok, event}
        end

      case outcome do
        {:ok, saved_event} ->
          case result_mode do
            :silent ->
              :ok

            :id ->
              {:ok, saved_event.id}

            :event ->
              {:ok, saved_event}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def flush(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @flush_interval_ms)
    EventBuffer.flush(timeout)
  end

  def query(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 100)
    EventStore.query(filters, page: page, page_size: page_size)
  end

  def actor_events(actor_id, since \\ nil) do
    filters = [actor_id: actor_id, since: since] |> Enum.reject(fn {_, v} -> is_nil(v) end)
    EventStore.query(filters)
  end

  defp maybe_validate(_event, false), do: :ok
  defp maybe_validate(event, true), do: Schema.validate(event)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
