```elixir
defmodule Observability.StructuredLogFormatter do
  use GenServer

  @moduledoc """
  Formats application log events into structured JSON-lines compatible with
  log aggregation platforms (Datadog, Loki, CloudWatch). Called by the logging
  pipeline before writing entries to the output sink.
  """


  @default_config %{
    service:          "app",
    env:              "production",
    version:          "unknown",
    redact_fields:    [:password, :token, :secret, :credit_card, :cvv, :ssn],
    redact_pattern:   "[REDACTED]",
    include_hostname: true,
    timestamp_format: :iso8601
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Formats a single log `event` map into a structured map using `config`.
  Returns `{:ok, formatted_map}`.
  """
  def format_entry(pid, event, config \\ @default_config) do
    GenServer.call(pid, {:format_entry, event, config})
  end

  @doc "Formats a list of events. Returns `{:ok, [formatted_map]}`."
  def format_batch(pid, events, config \\ @default_config) do
    GenServer.call(pid, {:format_batch, events, config})
  end

  @doc "Returns an event map with sensitive field values replaced."
  def redact_sensitive(pid, event, config \\ @default_config) do
    GenServer.call(pid, {:redact_sensitive, event, config})
  end

  @doc "Returns a newline-delimited JSON string for a list of events."
  def to_json_line(pid, events, config \\ @default_config) do
    GenServer.call(pid, {:to_json_line, events, config})
  end

  @doc "Returns the severity label string for an atom level."
  def severity_label(pid, level) do
    GenServer.call(pid, {:severity_label, level})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:format_entry, event, config}, _from, state) do
    formatted = build_entry(event, config)
    {:reply, {:ok, formatted}, state}
  end

  def handle_call({:format_batch, events, config}, _from, state) do
    formatted = Enum.map(events, fn e -> build_entry(e, config) end)
    {:reply, {:ok, formatted}, state}
  end

  def handle_call({:redact_sensitive, event, config}, _from, state) do
    redacted = do_redact(event, config.redact_fields, config.redact_pattern)
    {:reply, {:ok, redacted}, state}
  end

  def handle_call({:to_json_line, events, config}, _from, state) do
    lines =
      events
      |> Enum.map(fn e ->
        e |> build_entry(config) |> Jason.encode!()
      end)
      |> Enum.join("\n")

    {:reply, {:ok, lines}, state}
  end

  def handle_call({:severity_label, level}, _from, state) do
    label =
      case level do
        :debug    -> "DEBUG"
        :info     -> "INFO"
        :notice   -> "NOTICE"
        :warning  -> "WARN"
        :error    -> "ERROR"
        :critical -> "CRITICAL"
        :alert    -> "ALERT"
        :emergency -> "EMERGENCY"
        other     -> String.upcase(to_string(other))
      end

    {:reply, label, state}
  end

  ## Private helpers

  defp build_entry(event, config) do
    timestamp =
      case config.timestamp_format do
        :iso8601 -> DateTime.utc_now() |> DateTime.to_iso8601()
        :unix    -> System.system_time(:second)
      end

    base = %{
      timestamp: timestamp,
      level:     Map.get(event, :level, :info),
      message:   Map.get(event, :message, ""),
      service:   config.service,
      env:       config.env,
      version:   config.version
    }

    base
    |> maybe_add_hostname(config)
    |> maybe_add_trace(event)
    |> maybe_add_metadata(event)
    |> do_redact(config.redact_fields, config.redact_pattern)
  end

  defp maybe_add_hostname(entry, %{include_hostname: true}) do
    {:ok, hostname} = :inet.gethostname()
    Map.put(entry, :hostname, to_string(hostname))
  end
  defp maybe_add_hostname(entry, _), do: entry

  defp maybe_add_trace(entry, %{trace_id: tid, span_id: sid}) do
    Map.merge(entry, %{trace_id: tid, span_id: sid})
  end
  defp maybe_add_trace(entry, _), do: entry

  defp maybe_add_metadata(entry, event) do
    meta = Map.drop(event, [:level, :message, :trace_id, :span_id])
    if map_size(meta) > 0, do: Map.put(entry, :metadata, meta), else: entry
  end

  defp do_redact(map, fields, pattern) do
    Map.new(map, fn {k, v} ->
      if k in fields, do: {k, pattern}, else: {k, v}
    end)
  end

end
```
