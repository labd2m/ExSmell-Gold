```elixir
defmodule Database.ConnectionUrl do
  @moduledoc """
  Parses database connection URLs into typed configuration maps.

  Supported schemes: `postgres` / `postgresql`, `mysql` / `mysql2`,
  and `sqlite3`. Query string parameters are merged with the parsed
  host credentials so callers can pass options like `?pool_size=10`
  or `?ssl=true` directly in the URL without separate configuration.
  """

  @type adapter :: :postgrex | :myxql | :sqlite3

  @type t :: %__MODULE__{
          adapter: adapter(),
          host: String.t() | nil,
          port: non_neg_integer() | nil,
          database: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          options: %{String.t() => String.t()}
        }

  defstruct [:adapter, :host, :port, :database, :username, :password, options: %{}]

  @default_ports %{postgrex: 5432, myxql: 3306}

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_url | :unsupported_scheme}
  def parse(url) when is_binary(url) do
    with {:ok, uri} <- safe_parse(url),
         {:ok, adapter} <- resolve_adapter(uri.scheme),
         {:ok, database} <- extract_database(uri.path) do
      options = extract_options(uri.query)
      port = uri.port || Map.get(@default_ports, adapter)

      result = %__MODULE__{
        adapter: adapter,
        host: uri.host,
        port: port,
        database: database,
        username: decode_component(uri.userinfo, :username),
        password: decode_component(uri.userinfo, :password),
        options: options
      }

      {:ok, result}
    end
  end

  @spec to_keyword(t()) :: keyword()
  def to_keyword(%__MODULE__{} = conn) do
    base = [
      hostname: conn.host,
      port: conn.port,
      database: conn.database,
      username: conn.username,
      password: conn.password
    ]

    extra = Enum.flat_map(conn.options, fn
      {"pool_size", v} -> [pool_size: String.to_integer(v)]
      {"ssl", "true"} -> [ssl: true]
      {"ssl", "false"} -> [ssl: false]
      {"timeout", v} -> [timeout: String.to_integer(v)]
      _ -> []
    end)

    Enum.reject(base ++ extra, fn {_, v} -> is_nil(v) end)
  end

  @spec redact(t()) :: t()
  def redact(%__MODULE__{} = conn) do
    %{conn | password: if(conn.password, do: "[REDACTED]", else: nil)}
  end

  defp safe_parse(url) do
    case URI.parse(url) do
      %URI{scheme: nil} -> {:error, :invalid_url}
      uri -> {:ok, uri}
    end
  end

  defp resolve_adapter(scheme) when scheme in ["postgres", "postgresql"], do: {:ok, :postgrex}
  defp resolve_adapter(scheme) when scheme in ["mysql", "mysql2"], do: {:ok, :myxql}
  defp resolve_adapter("sqlite3"), do: {:ok, :sqlite3}
  defp resolve_adapter(nil), do: {:error, :invalid_url}
  defp resolve_adapter(_), do: {:error, :unsupported_scheme}

  defp extract_database(nil), do: {:error, :invalid_url}
  defp extract_database("/" <> db) when db != "", do: {:ok, URI.decode(db)}
  defp extract_database(db) when is_binary(db) and db != "", do: {:ok, URI.decode(db)}
  defp extract_database(_), do: {:error, :invalid_url}

  defp extract_options(nil), do: %{}
  defp extract_options(query), do: URI.decode_query(query)

  defp decode_component(nil, _), do: nil
  defp decode_component(userinfo, :username) do
    userinfo |> String.split(":") |> List.first() |> URI.decode()
  end
  defp decode_component(userinfo, :password) do
    case String.split(userinfo, ":", parts: 2) do
      [_, password] -> URI.decode(password)
      _ -> nil
    end
  end
end
```
