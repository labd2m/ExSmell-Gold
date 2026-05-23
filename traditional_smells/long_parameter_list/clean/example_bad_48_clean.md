```elixir
defmodule Analytics.Events do
  @moduledoc """
  Captures and routes user analytics events to downstream sinks
  (data warehouse, real-time stream, and A/B experimentation platform).
  """

  require Logger

  @max_event_name_length 128
  @sinks [:warehouse, :stream, :experiments]

  def track(
        user_id,
        session_id,
        event_name,
        event_category,
        properties,
        ip_address,
        user_agent,
        device_type,
        send_to_stream,
        send_to_experiments
      ) do
    with :ok <- validate_event_name(event_name),
         :ok <- validate_category(event_category),
         :ok <- validate_properties(properties) do
      event = %{
        id: generate_event_id(),
        actor: %{
          user_id: user_id,
          session_id: session_id,
          device_type: device_type,
          ip_address: anonymize_ip(ip_address),
          user_agent: user_agent
        },
        name: event_name,
        category: event_category,
        properties: properties,
        occurred_at: DateTime.utc_now(),
        routing: %{
          warehouse: true,
          stream: send_to_stream,
          experiments: send_to_experiments
        }
      }

      sinks_to_use =
        @sinks
        |> Enum.filter(fn sink -> event.routing[sink] end)

      results =
        Enum.map(sinks_to_use, fn sink ->
          case dispatch_to_sink(event, sink) do
            :ok ->
              {sink, :ok}

            {:error, reason} ->
              Logger.warning("Failed to dispatch event #{event.id} to #{sink}: #{inspect(reason)}")
              {sink, {:error, reason}}
          end
        end)

      failed = Enum.filter(results, fn {_, res} -> res != :ok end)

      if Enum.empty?(failed) do
        Logger.debug("Event #{event.id} (#{event_name}) dispatched to #{length(results)} sink(s)")
        {:ok, event.id}
      else
        {:partial, %{event_id: event.id, failures: failed}}
      end
    end
  end

  defp validate_event_name(name)
       when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= @max_event_name_length,
       do: :ok
  defp validate_event_name(_), do: {:error, "event_name must be a non-empty string up to #{@max_event_name_length} chars"}

  defp validate_category(cat) when cat in [:engagement, :conversion, :error, :navigation, :system], do: :ok
  defp validate_category(cat), do: {:error, "unknown event_category: #{inspect(cat)}"}

  defp validate_properties(props) when is_map(props), do: :ok
  defp validate_properties(_), do: {:error, "properties must be a map"}

  defp dispatch_to_sink(event, :warehouse) do
    Logger.debug("Writing event #{event.id} to warehouse queue")
    :ok
  end
  defp dispatch_to_sink(event, :stream) do
    Logger.debug("Publishing event #{event.id} to Kafka topic analytics.events")
    :ok
  end
  defp dispatch_to_sink(event, :experiments) do
    Logger.debug("Forwarding event #{event.id} to experimentation service")
    :ok
  end

  defp anonymize_ip(nil), do: nil
  defp anonymize_ip(ip) do
    parts = String.split(ip, ".")
    case parts do
      [a, b, _c, _d] -> "#{a}.#{b}.0.0"
      _ -> nil
    end
  end

  defp generate_event_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
