```elixir
defmodule Analytics.EventTracker do
  @moduledoc """
  Records user behaviour events, enriches them with server-side context,
  and forwards them to the analytics pipeline for downstream processing.
  """

  require Logger

  @max_property_keys  50
  @max_name_length    100
  @reserved_names     ~w(session_start session_end page_view)

  @type raw_event :: %{optional(atom()) => term()}

  @type enriched_event :: %{
          id: String.t(),
          name: String.t(),
          user_id: String.t() | nil,
          properties: map(),
          occurred_at: DateTime.t(),
          received_at: DateTime.t(),
          source: String.t()
        }

  @spec record(raw_event(), map()) :: {:ok, enriched_event()} | {:error, String.t()}
  def record(event, server_context) do
    name        = event[:name]
    user_id     = event[:user_id]
    properties  = event[:properties]
    occurred_at = event[:occurred_at]

    with :ok <- validate_name(name),
         :ok <- validate_properties(properties) do
      enriched = %{
        id: generate_id(),
        name: name,
        user_id: user_id,
        properties: enrich_properties(properties || %{}, server_context),
        occurred_at: occurred_at || DateTime.utc_now(),
        received_at: DateTime.utc_now(),
        source: Map.get(server_context, :source, "web")
      }

      forward_to_pipeline(enriched)

      Logger.debug("Event recorded",
        event_id: enriched.id,
        name: enriched.name,
        user_id: enriched.user_id
      )

      {:ok, enriched}
    end
  end

  @spec batch_record(list(raw_event()), map()) :: %{ok: integer(), error: integer()}
  def batch_record(events, server_context) do
    Enum.reduce(events, %{ok: 0, error: 0}, fn event, acc ->
      case record(event, server_context) do
        {:ok, _}    -> Map.update!(acc, :ok, &(&1 + 1))
        {:error, _} -> Map.update!(acc, :error, &(&1 + 1))
      end
    end)
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_name(nil), do: {:error, "Event name is required"}

  defp validate_name(name) when is_binary(name) do
    cond do
      String.length(name) > @max_name_length ->
        {:error, "Event name exceeds #{@max_name_length} characters"}

      name in @reserved_names ->
        {:error, "Event name '#{name}' is reserved for internal use"}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error, "Event name must be snake_case, got: #{name}"}

      true ->
        :ok
    end
  end

  defp validate_name(other), do: {:error, "Event name must be a string, got: #{inspect(other)}"}

  defp validate_properties(nil), do: :ok

  defp validate_properties(props) when is_map(props) do
    if map_size(props) > @max_property_keys do
      {:error, "Event properties exceed #{@max_property_keys} keys"}
    else
      :ok
    end
  end

  defp validate_properties(other),
    do: {:error, "Properties must be a map, got: #{inspect(other)}"}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp enrich_properties(props, context) do
    Map.merge(props, %{
      sdk_version: Map.get(context, :sdk_version, "unknown"),
      platform: Map.get(context, :platform, "unknown")
    })
  end

  defp forward_to_pipeline(event) do
    # Simulate forwarding to Kafka / PubSub in production
    Logger.debug("Forwarding event #{event.id} to pipeline")
    :ok
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
```
