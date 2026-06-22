```elixir
defmodule Streaming.SSEController do
  @moduledoc """
  Streams Server-Sent Events to connected HTTP clients using chunked
  transfer encoding. Each event is formatted per the SSE specification
  with optional `id`, `event`, and `retry` fields. The controller manages
  per-connection state and cleans up PubSub subscriptions when a client
  disconnects, preventing resource leaks on long-lived connections.
  """

  import Plug.Conn

  alias Plug.Conn

  @type sse_event :: %{
          optional(:id) => String.t(),
          optional(:event) => String.t(),
          optional(:data) => String.t(),
          optional(:retry) => pos_integer()
        }

  @keepalive_interval_ms 25_000
  @sse_content_type "text/event-stream; charset=utf-8"

  @doc """
  Initialises the SSE stream on `conn`, subscribing to `topic` on
  PubSub and looping until the client disconnects. Calls `event_mapper`
  to translate PubSub messages into `sse_event` maps; returning `nil`
  skips the message.
  """
  @spec stream(Conn.t(), String.t(), (term() -> sse_event() | nil)) :: Conn.t()
  def stream(%Conn{} = conn, topic, event_mapper)
      when is_binary(topic) and is_function(event_mapper, 1) do
    conn = init_sse_conn(conn)
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
    loop(conn, topic, event_mapper)
  end

  @doc "Formats a single SSE event map into its wire-format binary string."
  @spec format_event(sse_event()) :: String.t()
  def format_event(event) when is_map(event) do
    [
      event |> Map.get(:id) |> field_line("id"),
      event |> Map.get(:event) |> field_line("event"),
      event |> Map.get(:retry) |> retry_line(),
      event |> Map.get(:data, "") |> data_lines()
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> Kernel.<>("
")
  end

  defp init_sse_conn(conn) do
    conn
    |> put_resp_header("content-type", @sse_content_type)
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp loop(conn, topic, event_mapper) do
    receive do
      :keepalive ->
        case chunk(conn, ": keepalive

") do
          {:ok, conn} ->
            Process.send_after(self(), :keepalive, @keepalive_interval_ms)
            loop(conn, topic, event_mapper)

          {:error, _reason} ->
            cleanup(topic)
            conn
        end

      {:plug_conn, :sent} ->
        cleanup(topic)
        conn

      message ->
        case event_mapper.(message) do
          nil ->
            loop(conn, topic, event_mapper)

          event ->
            wire = format_event(event)

            case chunk(conn, wire) do
              {:ok, conn} -> loop(conn, topic, event_mapper)
              {:error, _reason} ->
                cleanup(topic)
                conn
            end
        end
    end
  end

  defp cleanup(topic) do
    Phoenix.PubSub.unsubscribe(MyApp.PubSub, topic)
  end

  defp field_line(nil, _name), do: nil
  defp field_line(value, name), do: "#{name}: #{value}
"

  defp retry_line(nil), do: nil
  defp retry_line(ms) when is_integer(ms), do: "retry: #{ms}
"

  defp data_lines(""), do: "data:
"
  defp data_lines(data) when is_binary(data) do
    data |> String.split("
") |> Enum.map(&"data: #{&1}
")
  end
end
```
