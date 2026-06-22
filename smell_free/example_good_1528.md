```elixir
defmodule Pipeline.DataNormalizer do
  @moduledoc """
  Multi-stage data normalization pipeline for inbound webhook event payloads.

  Each stage is a pure transformation function. Stages are composed via
  `run/2`, which threads the payload through each step and short-circuits
  on the first validation or transformation failure.
  """

  @type raw_payload :: map()
  @type normalized_event :: %{
          event_type: atom(),
          source: String.t(),
          occurred_at: DateTime.t(),
          actor_id: String.t(),
          metadata: map()
        }

  @type stage_result :: {:ok, map()} | {:error, atom(), String.t()}

  @doc """
  Runs a raw webhook payload through the full normalization pipeline.

  Returns `{:ok, normalized_event}` when all stages pass, or
  `{:error, stage, reason}` identifying where normalization failed.
  """
  @spec run(raw_payload()) :: {:ok, normalized_event()} | {:error, atom(), String.t()}
  def run(raw_payload) when is_map(raw_payload) do
    stages = [
      &validate_required_fields/1,
      &normalize_event_type/1,
      &parse_timestamp/1,
      &normalize_source/1,
      &extract_metadata/1
    ]

    Enum.reduce_while(stages, {:ok, raw_payload}, fn stage, {:ok, payload} ->
      case stage.(payload) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_required_fields(payload) do
    required = ~w(event_type source occurred_at actor_id)

    missing =
      Enum.reject(required, fn key -> Map.has_key?(payload, key) and payload[key] != nil end)

    case missing do
      [] -> {:ok, payload}
      fields -> {:error, :validation, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  defp normalize_event_type(%{"event_type" => raw_type} = payload) do
    case parse_event_type(raw_type) do
      {:ok, atom_type} -> {:ok, Map.put(payload, "event_type", atom_type)}
      :error -> {:error, :event_type, "Unknown event type: #{raw_type}"}
    end
  end

  defp parse_event_type("user.created"), do: {:ok, :user_created}
  defp parse_event_type("user.deleted"), do: {:ok, :user_deleted}
  defp parse_event_type("order.placed"), do: {:ok, :order_placed}
  defp parse_event_type("order.shipped"), do: {:ok, :order_shipped}
  defp parse_event_type("payment.received"), do: {:ok, :payment_received}
  defp parse_event_type(_), do: :error

  defp parse_timestamp(%{"occurred_at" => raw_ts} = payload) do
    case DateTime.from_iso8601(raw_ts) do
      {:ok, dt, _offset} -> {:ok, Map.put(payload, "occurred_at", dt)}
      {:error, _} -> {:error, :timestamp, "Invalid ISO 8601 timestamp: #{raw_ts}"}
    end
  end

  defp normalize_source(%{"source" => source} = payload) when is_binary(source) do
    normalized = source |> String.trim() |> String.downcase()

    if String.length(normalized) > 0 do
      {:ok, Map.put(payload, "source", normalized)}
    else
      {:error, :source, "Source must be a non-empty string"}
    end
  end

  defp normalize_source(_payload) do
    {:error, :source, "Source field must be a string"}
  end

  defp extract_metadata(payload) do
    metadata = Map.get(payload, "metadata", %{})

    normalized = %{
      event_type: payload["event_type"],
      source: payload["source"],
      occurred_at: payload["occurred_at"],
      actor_id: payload["actor_id"],
      metadata: metadata
    }

    {:ok, normalized}
  end
end
```
