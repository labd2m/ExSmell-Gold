```elixir
defmodule Reporting.AuditTrail do
  @moduledoc """
  Records and queries audit trail entries for compliance and security reporting.
  Each entry tracks who performed what action on which resource and when.
  """

  alias Reporting.{AuditEntry, AuditStore, Actor}

  @entry_types ~w(create update delete view export approve reject)a
  @id_prefix "AUD"
  @max_context_size_bytes 4096

  def record(actor_id, entry_type, resource_type, record_id, opts \\ []) do
    unless entry_type in @entry_types do
      raise ArgumentError, "Invalid audit entry type: #{inspect(entry_type)}"
    end

    context = Keyword.get(opts, :context, %{})
    ip_address = Keyword.get(opts, :ip_address, nil)
    session_id = Keyword.get(opts, :session_id, nil)

    with {:ok, actor} <- Actor.fetch(actor_id),
         {:ok, formatted_id} <- format_record_identifier(record_id),
         :ok <- validate_context_size(context) do
      entry = %AuditEntry{
        id: generate_entry_id(),
        actor_id: actor.id,
        actor_name: actor.display_name,
        entry_type: entry_type,
        resource_type: resource_type,
        record_id: formatted_id,
        context: context,
        ip_address: ip_address,
        session_id: session_id,
        occurred_at: DateTime.utc_now()
      }

      AuditStore.persist(entry)
      {:ok, entry.id}
    end
  end

  def format_record_identifier(record_id) do
    formatted =
      record_id
      |> to_string()
      |> String.trim()
      |> String.upcase()

    if formatted == "" do
      {:error, :empty_record_identifier}
    else
      {:ok, "#{@id_prefix}:#{formatted}"}
    end
  end

  def query(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    order = Keyword.get(opts, :order, :desc)

    AuditStore.search(filters, page: page, per_page: per_page, order: order)
  end

  def entries_for_record(resource_type, record_id) when is_binary(resource_type) do
    case format_record_identifier(record_id) do
      {:ok, formatted} ->
        AuditStore.search(%{resource_type: resource_type, record_id: formatted})

      {:error, _} = err ->
        err
    end
  end

  def entries_by_actor(actor_id, since \\ nil) do
    cutoff = since || DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
    AuditStore.search(%{actor_id: actor_id, from: cutoff})
  end

  def validate_context_size(context) when is_map(context) do
    encoded = Jason.encode!(context)

    if byte_size(encoded) > @max_context_size_bytes do
      {:error, {:context_too_large, byte_size(encoded), @max_context_size_bytes}}
    else
      :ok
    end
  end

  def generate_entry_id do
    ts = System.system_time(:microsecond)
    rand = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    "#{@id_prefix}-#{ts}-#{rand}"
  end

  def export_entries(filters, format) when format in [:csv, :json] do
    with {:ok, entries} <- query(filters, per_page: 10_000) do
      case format do
        :csv -> serialize_csv(entries)
        :json -> Jason.encode(Enum.map(entries, &AuditEntry.to_map/1))
      end
    end
  end

  defp serialize_csv(entries) do
    headers = "id,actor_id,actor_name,entry_type,resource_type,record_id,occurred_at"

    rows =
      Enum.map(entries, fn e ->
        "#{e.id},#{e.actor_id},#{e.actor_name},#{e.entry_type},#{e.resource_type},#{e.record_id},#{DateTime.to_iso8601(e.occurred_at)}"
      end)

    {:ok, Enum.join([headers | rows], "\n")}
  end
end
```
