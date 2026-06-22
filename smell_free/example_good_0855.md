```elixir
defmodule Platform.RequestContextPlug do
  @moduledoc """
  Populates request context metadata for every incoming HTTP request.
  Assigns a unique request ID, records the start timestamp, extracts
  client locale and time zone from Accept-Language and X-Timezone headers,
  and logs a structured request summary. All assigns are available to
  downstream plugs and controllers without repeated header parsing.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @request_id_header "x-request-id"
  @timezone_header "x-timezone"
  @accept_language_header "accept-language"
  @default_locale "en"
  @default_timezone "Etc/UTC"
  @id_bytes 8

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, _opts) do
    request_id = resolve_request_id(conn)
    locale = resolve_locale(conn)
    timezone = resolve_timezone(conn)
    start_time = System.monotonic_time(:microsecond)

    conn
    |> assign(:request_id, request_id)
    |> assign(:locale, locale)
    |> assign(:timezone, timezone)
    |> assign(:request_start_us, start_time)
    |> put_req_header(@request_id_header, request_id)
    |> put_resp_header(@request_id_header, request_id)
    |> register_before_send(&log_completion(&1, request_id, start_time))
  end

  @doc "Resolves or generates the request ID from the incoming header."
  @spec resolve_request_id(Plug.Conn.t()) :: String.t()
  def resolve_request_id(conn) do
    case get_req_header(conn, @request_id_header) do
      [id | _] when is_binary(id) and byte_size(id) > 0 -> id
      _ -> generate_id()
    end
  end

  defp resolve_locale(conn) do
    case get_req_header(conn, @accept_language_header) do
      [header | _] -> parse_primary_locale(header)
      [] -> @default_locale
    end
  end

  defp resolve_timezone(conn) do
    case get_req_header(conn, @timezone_header) do
      [tz | _] when is_binary(tz) and byte_size(tz) > 0 -> sanitise_timezone(tz)
      _ -> @default_timezone
    end
  end

  defp parse_primary_locale(header) do
    header
    |> String.split(",")
    |> List.first("")
    |> String.split(";")
    |> List.first("")
    |> String.trim()
    |> String.slice(0, 5)
    |> then(fn s -> if byte_size(s) == 0, do: @default_locale, else: s end)
  end

  defp sanitise_timezone(tz) do
    if String.match?(tz, ~r/^[A-Za-z0-9\/\-_+:]+$/) and byte_size(tz) <= 50 do
      tz
    else
      @default_timezone
    end
  end

  defp log_completion(conn, request_id, start_us) do
    duration_ms = div(System.monotonic_time(:microsecond) - start_us, 1_000)

    Logger.info("[Request] #{conn.method} #{conn.request_path} → #{conn.status} (#{duration_ms}ms)",
      request_id: request_id,
      status: conn.status,
      duration_ms: duration_ms
    )

    conn
  end

  defp generate_id do
    :crypto.strong_rand_bytes(@id_bytes) |> Base.encode16(case: :lower)
  end
end
```
