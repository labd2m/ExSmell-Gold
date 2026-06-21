```elixir
defmodule Telemetry.MetricEvent do
  @moduledoc false

  @type t :: %__MODULE__{
          key: String.t(),
          measurements: map(),
          metadata: map(),
          timestamp_ms: non_neg_integer()
        }

  defstruct [:key, :measurements, :metadata, :timestamp_ms]
end

defmodule Telemetry.StatsdBackend do
  @moduledoc """
  Forwards metric events to a StatsD-compatible UDP endpoint.

  Each measurement within an event is emitted as a separate gauge metric.
  Non-numeric measurements are silently skipped to avoid protocol errors.
  """

  alias Telemetry.MetricEvent

  @type opts :: [host: String.t(), port: :inet.port_number(), prefix: String.t()]

  @spec report(MetricEvent.t(), opts()) :: :ok
  def report(%MetricEvent{key: key, measurements: measurements}, opts) do
    prefix = Keyword.get(opts, :prefix, "")

    Enum.each(measurements, fn {measure, value} ->
      if is_number(value) do
        metric_key = build_metric_key(prefix, key, measure)
        emit_gauge(metric_key, value, opts)
      end
    end)
  end

  defp build_metric_key("", key, measure), do: "#{key}.#{measure}"
  defp build_metric_key(prefix, key, measure), do: "#{prefix}.#{key}.#{measure}"

  defp emit_gauge(key, value, opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 8125)
    payload = "#{key}:#{value}|g"

    case :gen_udp.open(0) do
      {:ok, socket} ->
        :gen_udp.send(socket, to_charlist(host), port, payload)
        :gen_udp.close(socket)

      {:error, _reason} ->
        :ok
    end
  end
end

defmodule Telemetry.Reporter do
  @moduledoc """
  Attaches named telemetry handlers and forwards aggregated measurements
  to a configured metrics backend.

  Handlers are registered with deterministic IDs derived from the event
  name so attaching the same event list twice is idempotent. The backend
  module and its options are captured in the handler configuration at
  attachment time, making the reporter usable with any backend that
  implements `report/2`.
  """

  alias Telemetry.MetricEvent

  @type event_name :: [atom()]
  @type attach_opts :: [
          prefix: String.t(),
          backend: module(),
          backend_opts: keyword()
        ]

  @spec attach(event_name(), attach_opts()) :: :ok | {:error, :already_attached}
  def attach(event_name, opts \\ []) when is_list(event_name) do
    handler_id = handler_id_for(event_name)
    config = build_config(opts)

    :telemetry.attach(handler_id, event_name, &handle_event/4, config)
    |> normalize_attach_result()
  end

  @spec attach_many([event_name()], attach_opts()) :: :ok
  def attach_many(event_names, opts \\ []) when is_list(event_names) do
    Enum.each(event_names, &attach(&1, opts))
  end

  @spec detach(event_name()) :: :ok | {:error, :not_found}
  def detach(event_name) when is_list(event_name) do
    :telemetry.detach(handler_id_for(event_name))
  end

  defp handle_event(event_name, measurements, metadata, config) do
    event = %MetricEvent{
      key: Enum.map_join(event_name, ".", &Atom.to_string/1),
      measurements: measurements,
      metadata: metadata,
      timestamp_ms: System.system_time(:millisecond)
    }

    config.backend.report(event, config.backend_opts)
  end

  defp build_config(opts) do
    %{
      prefix: Keyword.get(opts, :prefix, ""),
      backend: Keyword.get(opts, :backend, Telemetry.StatsdBackend),
      backend_opts: Keyword.get(opts, :backend_opts, [])
    }
  end

  defp handler_id_for(event_name) do
    "telemetry_reporter:" <> Enum.map_join(event_name, ".", &Atom.to_string/1)
  end

  defp normalize_attach_result(:ok), do: :ok
  defp normalize_attach_result({:error, :already_exists}), do: {:error, :already_attached}
end
```
