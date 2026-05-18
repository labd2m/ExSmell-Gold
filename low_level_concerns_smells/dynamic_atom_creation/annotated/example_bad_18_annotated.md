# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `AuditLogConsumer.decode_message/1`, line where `String.to_atom/1` converts the action string from the Kafka message |
| **Affected function(s)** | `AuditLogConsumer.decode_message/1` |
| **Short explanation** | Audit log messages are consumed from a Kafka topic. Each message carries an `"action"` field that identifies the operation performed. Converting this field with `String.to_atom/1` means every new action string introduced by any producer—across all services writing to the topic—will permanently claim an atom table slot. |

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

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` converts the `"action"`
  # field from a Kafka message payload. Audit log producers across dozens of
  # microservices can each publish their own action identifiers (e.g.,
  # "user.password_reset_v2", "order.line_item.quantity_adjusted"). As the
  # organization grows and services evolve, the number of distinct action strings
  # grows without bound. Each unique string permanently allocates an atom.
  # In a high-throughput audit consumer, this is particularly risky because the
  # allocation occurs for every novel message seen—there is no upper bound enforced.
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
  # VALIDATION: SMELL END

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
