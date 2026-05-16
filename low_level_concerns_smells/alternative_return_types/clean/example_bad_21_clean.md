```elixir
defmodule MyApp.Audit.Trail do
  @moduledoc """
  Records auditable events for compliance and forensic investigation.
  Covers authentication, data access, configuration changes, and
  administrative actions across all bounded contexts.
  """

  alias MyApp.Audit.EventStore
  alias MyApp.Audit.AsyncQueue
  alias MyApp.Audit.Enricher
  alias MyApp.Audit.Schema

  @event_types [
    :login, :logout, :password_changed, :role_changed,
    :record_created, :record_updated, :record_deleted,
    :export_requested, :config_changed, :api_key_issued
  ]

  defstruct [
    :id, :event_type, :actor_id, :actor_ip,
    :resource_type, :resource_id, :changes,
    :metadata, :occurred_at, :trace_id
  ]

  def event_types, do: @event_types

  def record_event(attrs, opts \\ []) when is_list(opts) do
    persist = Keyword.get(opts, :persist, :sync)
    enrich = Keyword.get(opts, :enrich, true)
    trace_id = Keyword.get(opts, :trace_id)

    unless attrs[:event_type] in @event_types do
      raise ArgumentError, "unknown event type: #{inspect(attrs[:event_type])}"
    end

    raw_event = %__MODULE__{
      id: generate_id(),
      event_type: attrs[:event_type],
      actor_id: attrs[:actor_id],
      actor_ip: attrs[:actor_ip],
      resource_type: attrs[:resource_type],
      resource_id: attrs[:resource_id],
      changes: attrs[:changes] || %{},
      metadata: attrs[:metadata] || %{},
      occurred_at: DateTime.utc_now(),
      trace_id: trace_id
    }

    event = if enrich, do: Enricher.enrich(raw_event), else: raw_event

    case persist do
      :none ->
        event

      :sync ->
        case EventStore.insert(event) do
          {:ok, saved} -> {:ok, saved}
          {:error, reason} -> {:error, reason}
        end

      :async ->
        AsyncQueue.enqueue(event)
        :async
    end
  end
  
  def query(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 50)
    EventStore.query(filters, page: page, page_size: page_size)
  end

  def actor_history(actor_id, since \\ nil) do
    filters = [actor_id: actor_id]
    filters = if since, do: Keyword.put(filters, :since, since), else: filters
    EventStore.query(filters)
  end

  def resource_history(resource_type, resource_id) do
    EventStore.query(resource_type: resource_type, resource_id: resource_id)
  end

  def export_range(from, to, format \\ :json) do
    EventStore.export(from, to, format)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
  end
end
```
