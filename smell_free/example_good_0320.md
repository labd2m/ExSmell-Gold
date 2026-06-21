```elixir
defmodule Gateway.ApiVersion do
  @moduledoc """
  Represents a parsed, validated API version.
  """

  @type t :: %__MODULE__{major: pos_integer(), minor: non_neg_integer()}

  defstruct [:major, :minor]

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_version}
  def parse("v" <> rest), do: parse(rest)

  def parse(string) when is_binary(string) do
    case String.split(string, ".") do
      [major] ->
        with {:ok, maj} <- parse_int(major) do
          {:ok, %__MODULE__{major: maj, minor: 0}}
        end

      [major, minor] ->
        with {:ok, maj} <- parse_int(major),
             {:ok, min} <- parse_int(minor) do
          {:ok, %__MODULE__{major: maj, minor: min}}
        end

      _ ->
        {:error, :invalid_version}
    end
  end

  def parse(_), do: {:error, :invalid_version}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{major: maj, minor: 0}), do: "v#{maj}"
  def to_string(%__MODULE__{major: maj, minor: min}), do: "v#{maj}.#{min}"

  @spec supported?([t()], t()) :: boolean()
  def supported?(supported_versions, %__MODULE__{} = version) do
    Enum.any?(supported_versions, fn v -> v.major == version.major end)
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_version}
    end
  end
end

defmodule Gateway.Plugs.ApiVersioning do
  @moduledoc """
  Extracts and validates the API version from an incoming request.

  Version resolution checks, in order: a path segment prefix (`/v2/...`),
  then the `Accept-Version` header. The resolved version is placed in
  assigns so downstream routers can dispatch to versioned handler modules.
  Requests specifying an unsupported version are rejected with HTTP 400.
  """

  @behaviour Plug

  alias Gateway.ApiVersion
  alias Plug.Conn

  @impl Plug
  def init(opts) do
    supported =
      opts
      |> Keyword.fetch!(:supported_versions)
      |> Enum.map(fn v ->
        {:ok, parsed} = ApiVersion.parse(v)
        parsed
      end)

    %{supported: supported, default: Keyword.get(opts, :default, "v1")}
  end

  @impl Plug
  def call(%Conn{} = conn, %{supported: supported, default: default}) do
    with {:ok, raw_version} <- extract_version(conn, default),
         {:ok, version} <- ApiVersion.parse(raw_version),
         true <- ApiVersion.supported?(supported, version) do
      conn
      |> Conn.assign(:api_version, version)
      |> strip_version_prefix(version)
    else
      false -> reject(conn, "API version #{extract_raw(conn)} is no longer supported")
      {:error, :invalid_version} -> reject(conn, "Invalid API version format")
    end
  end

  defp extract_version(%Conn{path_info: [<<"v", _::binary>> = v | _]}, _default), do: {:ok, v}

  defp extract_version(conn, default) do
    case Conn.get_req_header(conn, "accept-version") do
      [version | _] -> {:ok, version}
      [] -> {:ok, default}
    end
  end

  defp extract_raw(%Conn{path_info: [<<"v", _::binary>> = v | _]}), do: v
  defp extract_raw(conn), do: Conn.get_req_header(conn, "accept-version") |> List.first("unknown")

  defp strip_version_prefix(%Conn{path_info: [<<"v", _::binary>> | rest]} = conn, _version) do
    %{conn | path_info: rest}
  end

  defp strip_version_prefix(conn, _version), do: conn

  defp reject(conn, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(400, body)
    |> Conn.halt()
  end
end
```
