```elixir
defmodule AppWeb.Plugs.ContentNegotiation do
  @moduledoc """
  A Plug that negotiates the response format based on the `Accept` header
  and assigns `conn.assigns.response_format` for downstream use.

  Supported formats and their MIME types are configured per mount.
  When no matching format is found, the Plug either uses the default or
  halts with `406 Not Acceptable`, depending on the `:strict` option.
  """

  import Plug.Conn

  @behaviour Plug

  @type format :: :json | :html | :xml | :csv | :text
  @type opt ::
          {:formats, [format()]}
          | {:default, format()}
          | {:strict, boolean()}

  @mime_map %{
    "application/json" => :json,
    "application/vnd.api+json" => :json,
    "text/html" => :html,
    "application/xhtml+xml" => :html,
    "application/xml" => :xml,
    "text/xml" => :xml,
    "text/csv" => :csv,
    "text/plain" => :text,
    "*/*" => :any
  }

  @impl Plug
  def init(opts) do
    %{
      formats: Keyword.get(opts, :formats, [:json, :html]),
      default: Keyword.get(opts, :default, :json),
      strict: Keyword.get(opts, :strict, false)
    }
  end

  @impl Plug
  def call(conn, %{formats: allowed, default: default, strict: strict}) do
    accepted = parse_accept_header(conn)
    resolved = resolve_format(accepted, allowed)

    case resolved do
      nil when strict ->
        reject(conn, allowed)

      nil ->
        assign(conn, :response_format, default)

      format ->
        assign(conn, :response_format, format)
    end
  end

  @doc "Returns the negotiated response format for the connection."
  @spec format(Plug.Conn.t()) :: format() | nil
  def format(conn), do: conn.assigns[:response_format]

  @doc "Returns `true` if the negotiated format matches `expected`."
  @spec format?(Plug.Conn.t(), format()) :: boolean()
  def format?(conn, expected), do: conn.assigns[:response_format] == expected

  defp parse_accept_header(conn) do
    conn
    |> get_req_header("accept")
    |> List.first("")
    |> String.split(",")
    |> Enum.map(&parse_media_type/1)
    |> Enum.sort_by(fn {_mime, q} -> -q end)
    |> Enum.map(fn {mime, _q} -> mime end)
  end

  defp parse_media_type(raw) do
    [media_type | params] = String.split(String.trim(raw), ";")
    q = extract_quality(params)
    {String.trim(media_type), q}
  end

  defp extract_quality(params) do
    Enum.find_value(params, 1.0, fn param ->
      case String.trim(param) do
        "q=" <> q_str ->
          case Float.parse(q_str) do
            {q, _} -> q
            :error -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp resolve_format(accepted_mimes, allowed_formats) do
    Enum.find_value(accepted_mimes, fn mime ->
      format = Map.get(@mime_map, mime)

      cond do
        format == :any -> List.first(allowed_formats)
        format in allowed_formats -> format
        true -> nil
      end
    end)
  end

  defp reject(conn, allowed_formats) do
    accept_header = Enum.map_join(allowed_formats, ", ", &format_to_mime/1)

    conn
    |> put_resp_header("accept", accept_header)
    |> put_resp_content_type("application/json")
    |> send_resp(406, Jason.encode!(%{error: "not_acceptable", supported: Enum.map(allowed_formats, &Atom.to_string/1)}))
    |> halt()
  end

  defp format_to_mime(:json), do: "application/json"
  defp format_to_mime(:html), do: "text/html"
  defp format_to_mime(:xml), do: "application/xml"
  defp format_to_mime(:csv), do: "text/csv"
  defp format_to_mime(:text), do: "text/plain"
end
```
