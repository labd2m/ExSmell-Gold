```elixir
defmodule AppWeb.Plugs.ApiVersioning do
  @moduledoc """
  A Plug that negotiates and enforces API versioning for JSON HTTP endpoints.

  The requested version is read from the `Accept` header using media type
  parameters (e.g. `application/json; version=2`) or from an explicit
  `X-API-Version` header. The resolved version is assigned to
  `conn.assigns.api_version` for downstream routers and controllers.
  """

  import Plug.Conn

  @behaviour Plug

  @type version :: pos_integer()
  @type opt :: {:supported_versions, [version()]} | {:default_version, version()}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    supported = Keyword.fetch!(opts, :supported_versions)
    default = Keyword.get(opts, :default_version, List.last(supported))
    deprecated = Keyword.get(opts, :deprecated_versions, [])

    with {:ok, requested} <- resolve_version(conn),
         :ok <- validate_version(requested, supported) do
      conn
      |> assign(:api_version, requested)
      |> warn_if_deprecated(requested, deprecated)
    else
      {:error, :no_version_specified} ->
        conn
        |> assign(:api_version, default)
        |> warn_if_deprecated(default, deprecated)

      {:error, {:unsupported_version, version}} ->
        reject_unsupported(conn, version, supported)
    end
  end

  defp resolve_version(conn) do
    case resolve_from_header(conn) do
      {:ok, _} = result -> result
      {:error, :not_found} -> resolve_from_accept(conn)
      {:error, :invalid_format} = err -> err
    end
  end

  defp resolve_from_header(conn) do
    case get_req_header(conn, "x-api-version") do
      [raw | _] -> parse_version(raw)
      [] -> {:error, :not_found}
    end
  end

  defp resolve_from_accept(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> extract_version_from_accept(accept)
      [] -> {:error, :no_version_specified}
    end
  end

  defp extract_version_from_accept(accept) do
    case Regex.run(~r/version=(\d+)/, accept, capture: :all_but_first) do
      [version_str] -> parse_version(version_str)
      nil -> {:error, :no_version_specified}
    end
  end

  defp parse_version(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {version, ""} when version > 0 -> {:ok, version}
      _ -> {:error, :invalid_format}
    end
  end

  defp validate_version(version, supported) do
    if version in supported do
      :ok
    else
      {:error, {:unsupported_version, version}}
    end
  end

  defp warn_if_deprecated(conn, version, deprecated) do
    if version in deprecated do
      put_resp_header(conn, "deprecation", "true")
    else
      conn
    end
  end

  defp reject_unsupported(conn, version, supported) do
    body = Jason.encode!(%{
      error: "unsupported_api_version",
      requested: version,
      supported: supported
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
    |> halt()
  end
end
```
