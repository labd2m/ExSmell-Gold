```elixir
defmodule AppWeb.Plugs.RequestTracing do
  @moduledoc """
  A Plug that establishes distributed tracing context for every request.

  Accepts an incoming `X-Trace-Id` header from upstream services and
  propagates it downstream. Generates a new trace ID when none is present.
  Both the trace ID and a per-request span ID are injected into the Logger
  metadata for structured log correlation across services.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @trace_header "x-trace-id"
  @span_header "x-span-id"
  @parent_span_header "x-parent-span-id"
  @id_bytes 12

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    trace_id = resolve_trace_id(conn)
    parent_span_id = get_incoming_span_id(conn)
    span_id = generate_id()

    Logger.metadata(
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id
    )

    conn
    |> assign(:trace_id, trace_id)
    |> assign(:span_id, span_id)
    |> assign(:parent_span_id, parent_span_id)
    |> put_resp_header(@trace_header, trace_id)
    |> put_resp_header(@span_header, span_id)
    |> register_before_send(&clear_logger_metadata/1)
  end

  @doc """
  Builds a map of tracing headers to forward in outbound HTTP requests.
  Pull from `conn.assigns` to ensure the current trace context is propagated.
  """
  @spec outbound_headers(Plug.Conn.t()) :: [{String.t(), String.t()}]
  def outbound_headers(conn) do
    [
      {@trace_header, conn.assigns[:trace_id] || generate_id()},
      {@parent_span_header, conn.assigns[:span_id] || generate_id()}
    ]
  end

  @doc "Returns the trace ID for the current request."
  @spec trace_id(Plug.Conn.t()) :: String.t() | nil
  def trace_id(conn), do: conn.assigns[:trace_id]

  @doc "Returns the span ID for the current request."
  @spec span_id(Plug.Conn.t()) :: String.t() | nil
  def span_id(conn), do: conn.assigns[:span_id]

  defp resolve_trace_id(conn) do
    case get_req_header(conn, @trace_header) do
      [id | _] when byte_size(id) > 0 and byte_size(id) <= 128 -> id
      _ -> generate_id()
    end
  end

  defp get_incoming_span_id(conn) do
    case get_req_header(conn, @span_header) do
      [id | _] when byte_size(id) > 0 -> id
      _ -> nil
    end
  end

  defp clear_logger_metadata(conn) do
    Logger.metadata(trace_id: nil, span_id: nil, parent_span_id: nil)
    conn
  end

  defp generate_id do
    @id_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
```
