```elixir
defmodule MyApp.Plug.RequestInstrumentation do
  @moduledoc """
  Injects a unique request ID into every HTTP connection and emits
  telemetry events at request start and completion. The request ID is
  written to both the request and response headers and assigned to
  `conn.assigns.request_id` for downstream consumption.
  """

  @behaviour Plug

  alias Plug.Conn

  @request_id_header "x-request-id"
  @id_byte_length 8
  @start_event [:my_app, :http, :start]
  @stop_event [:my_app, :http, :stop]

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(%Conn{} = conn, _opts) do
    request_id = resolve_request_id(conn)
    start_mono = System.monotonic_time()

    :telemetry.execute(@start_event, %{system_time: System.system_time()}, %{
      request_id: request_id,
      method: conn.method,
      path: conn.request_path
    })

    conn
    |> Conn.assign(:request_id, request_id)
    |> Conn.put_req_header(@request_id_header, request_id)
    |> Conn.put_resp_header(@request_id_header, request_id)
    |> Conn.register_before_send(fn completed_conn ->
      emit_stop(completed_conn, request_id, start_mono)
      completed_conn
    end)
  end

  defp resolve_request_id(conn) do
    case Conn.get_req_header(conn, @request_id_header) do
      [id | _] when is_binary(id) and byte_size(id) > 0 -> id
      _ -> generate_id()
    end
  end

  defp generate_id do
    @id_byte_length |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp emit_stop(conn, request_id, start_mono) do
    duration = System.monotonic_time() - start_mono

    :telemetry.execute(@stop_event, %{duration: duration}, %{
      request_id: request_id,
      status: conn.status,
      method: conn.method,
      path: conn.request_path
    })
  end
end

defmodule MyApp.Telemetry.HTTPLogger do
  @moduledoc """
  Attaches structured logging handlers to HTTP lifecycle telemetry events
  emitted by `MyApp.Plug.RequestInstrumentation`. Call `attach/0` once
  from your application's `start/2` callback.
  """

  require Logger

  @handler_id "my-app-http-logger"
  @events [[:my_app, :http, :start], [:my_app, :http, :stop]]

  @doc """
  Attaches all HTTP telemetry event handlers. Safe to call at startup.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &handle_event/4, nil)
  end

  @doc false
  def handle_event([:my_app, :http, :start], _measurements, meta, _config) do
    Logger.metadata(request_id: meta.request_id)
    Logger.debug("→ #{meta.method} #{meta.path}")
    :ok
  end

  def handle_event([:my_app, :http, :stop], %{duration: dur}, meta, _config) do
    ms = System.convert_time_unit(dur, :native, :millisecond)
    Logger.info("← #{meta.method} #{meta.path} #{meta.status} (#{ms}ms)")
    :ok
  end
end
```
