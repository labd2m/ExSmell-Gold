```elixir
defmodule MyApp.AuditLog.AuditLogConsumer do
  @moduledoc """
  Kafka consumer that processes audit log events from all internal services.
  Decoded audit records are persisted to the audit database and indexed
  for compliance search.
  """

  use Broadway

  require Logger

  alias MyApp.AuditLog.{AuditRecord, AuditRepo, ComplianceIndexer}

  @doc """
  Broadway pipeline configuration. Called by the supervisor.
  """
  def start_link(opts) do
    Broadway.start_link(__MODULE__, broadway_config(opts))
  end

  @impl Broadway
  def handle_message(_, %Broadway.Message{data: raw_data} = message, _context) do
    case process_message(raw_data) do
      {:ok, _record} ->
        message

      {:error, reason} ->
        Logger.warning("Failed to process audit message", reason: inspect(reason))
        Broadway.Message.failed(message, reason)
    end
  end

  @impl Broadway
  def handle_batch(:default, messages, _info, _context) do
    records =
      messages
      |> Enum.map(& &1.data)
      |> Enum.flat_map(fn data ->
        case process_message(data) do
          {:ok, record} -> [record]
          _ -> []
        end
      end)

    AuditRepo.insert_batch(records)
    ComplianceIndexer.index_batch(records)

    messages
  end

  defp process_message(raw_data) when is_binary(raw_data) do
    with {:ok, payload} <- Jason.decode(raw_data),
         {:ok, record} <- decode_message(payload) do
      {:ok, record}
    end
  end

  defp process_message(_), do: {:error, :non_binary_data}

  defp decode_message(%{
         "action" => action,
         "actor_id" => actor_id,
         "resource_type" => resource_type,
         "resource_id" => resource_id,
         "timestamp" => ts
       } = payload) do
    record = %AuditRecord{
      id: MyApp.UUID.generate(),
      action: String.to_atom(action),
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: Map.get(payload, "metadata", %{}),
      ip_address: Map.get(payload, "ip_address"),
      occurred_at: parse_timestamp(ts),
      ingested_at: DateTime.utc_now()
    }

    {:ok, record}
  end

  defp decode_message(payload) do
    Logger.warning("Malformed audit message", keys: Map.keys(payload))
    {:error, :malformed_audit_message}
  end

  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts, :millisecond)

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp broadway_config(opts) do
    [
      name: __MODULE__,
      producer: [
        module: {BroadwayKafka.Producer, kafka_config(opts)},
        concurrency: 2
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        default: [batch_size: 100, batch_timeout: 1_000, concurrency: 4]
      ]
    ]
  end

  defp kafka_config(opts) do
    [
      hosts: Keyword.fetch!(opts, :kafka_hosts),
      group_id: "audit-log-consumer",
      topics: ["audit-events"],
      client_config: [ssl: true]
    ]
  end
end
```
