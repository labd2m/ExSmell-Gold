# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `TelemetryHandler.normalize_event_name/1`, line where `Enum.map` applies `String.to_atom/1` to event name segments |
| **Affected function(s)** | `TelemetryHandler.normalize_event_name/1` |
| **Short explanation** | Telemetry event names arrive as dot-separated strings from external instrumentation agents and are split and converted to atom lists. Because telemetry event names can be arbitrary—especially from third-party libraries or dynamic instrumentation—each unique segment permanently allocates an atom. |

```elixir
defmodule MyApp.Observability.TelemetryHandler do
  @moduledoc """
  Aggregates telemetry events from all instrumented subsystems and
  forwards metrics to the configured StatsD backend.
  """

  require Logger

  alias MyApp.Observability.{StatsDClient, MetricNormalizer}

  @handler_id "myapp-telemetry-handler"

  @known_events [
    [:myapp, :repo, :query],
    [:myapp, :http, :request, :stop],
    [:myapp, :cache, :hit],
    [:myapp, :cache, :miss],
    [:myapp, :job, :start],
    [:myapp, :job, :stop],
    [:myapp, :job, :exception]
  ]

  @doc """
  Attaches the handler to all known telemetry events.
  Should be called during application startup.
  """
  @spec attach_all() :: :ok
  def attach_all do
    :telemetry.attach_many(
      @handler_id,
      @known_events,
      &__MODULE__.handle_event/4,
      %{}
    )

    Logger.info("TelemetryHandler attached to #{length(@known_events)} events")
    :ok
  end

  @doc """
  Attaches the handler to a dynamically specified event name string.
  Used by runtime instrumentation to subscribe to plugin-emitted events.
  """
  @spec attach_dynamic(String.t()) :: :ok | {:error, term()}
  def attach_dynamic(event_name_string) when is_binary(event_name_string) do
    with {:ok, event_name} <- normalize_event_name(event_name_string) do
      :telemetry.attach(
        "#{@handler_id}:#{event_name_string}",
        event_name,
        &__MODULE__.handle_event/4,
        %{dynamic: true}
      )
    end
  end

  @doc """
  Telemetry event handler callback. Converts measurements and metadata
  into StatsD metrics.
  """
  def handle_event(event_name, measurements, metadata, _config) do
    metric_name = Enum.join(event_name, ".")

    Enum.each(measurements, fn {key, value} when is_number(value) ->
      full_key = "#{metric_name}.#{key}"
      tags = build_tags(metadata)
      StatsDClient.gauge(full_key, value, tags: tags)
    end)
  rescue
    e ->
      Logger.error("TelemetryHandler crashed during event processing",
        event: inspect(event_name),
        error: Exception.message(e)
      )
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to every
  # segment of an event name string that comes from a runtime/dynamic registration
  # call. Plugin authors or external agents can attach arbitrary event names like
  # "my_plugin.v2.db_call.stop". Each unique segment permanently creates an atom.
  # In a system with many plugins or high plugin churn, this will accumulate atoms
  # without bound. The `:telemetry` library itself uses atom lists internally, but
  # that does not justify creating new atoms from external strings; a validation
  # step against a registry of permitted events should precede any conversion.
  defp normalize_event_name(event_string) when is_binary(event_string) do
    event_name =
      event_string
      |> String.split(".")
      |> Enum.map(&String.to_atom/1)

    {:ok, event_name}
  end
  # VALIDATION: SMELL END

  defp normalize_event_name(_), do: {:error, :invalid_event_name}

  defp build_tags(metadata) do
    []
    |> maybe_add_tag("env", Application.get_env(:myapp, :env, "production"))
    |> maybe_add_tag("host", metadata[:host])
    |> maybe_add_tag("region", metadata[:region])
    |> maybe_add_tag("service", metadata[:service])
  end

  defp maybe_add_tag(tags, _key, nil), do: tags
  defp maybe_add_tag(tags, key, value), do: ["#{key}:#{value}" | tags]
end
```
