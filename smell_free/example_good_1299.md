**File:** `example_good_1299.md`

```elixir
defmodule AppConfig.DatabaseConfig do
  @moduledoc "Validated configuration for a database connection pool."

  @enforce_keys [:host, :port, :database, :username, :pool_size]
  defstruct [:host, :port, :database, :username, :password, :pool_size, :ssl]

  @type t :: %__MODULE__{
          host: String.t(),
          port: pos_integer(),
          database: String.t(),
          username: String.t(),
          password: String.t() | nil,
          pool_size: pos_integer(),
          ssl: boolean()
        }
end

defmodule AppConfig.ServerConfig do
  @moduledoc "Validated configuration for the HTTP server."

  @enforce_keys [:host, :port]
  defstruct [:host, :port, http2: false, request_timeout_ms: 30_000]

  @type t :: %__MODULE__{
          host: String.t(),
          port: pos_integer(),
          http2: boolean(),
          request_timeout_ms: pos_integer()
        }
end

defmodule AppConfig.Loader do
  @moduledoc """
  Loads and validates application configuration from runtime environment.
  All config is resolved at startup and passed explicitly; never fetched
  mid-request from the Application environment.
  """

  alias AppConfig.{DatabaseConfig, ServerConfig}

  @type load_result :: {:ok, %{db: DatabaseConfig.t(), server: ServerConfig.t()}} | {:error, [String.t()]}

  @spec load(map()) :: load_result()
  def load(raw \\ %{}) when is_map(raw) do
    db_result = load_database_config(Map.get(raw, :database, %{}))
    server_result = load_server_config(Map.get(raw, :server, %{}))

    errors =
      [db_result, server_result]
      |> Enum.flat_map(fn
        {:error, errs} -> errs
        {:ok, _} -> []
      end)

    if errors == [] do
      {:ok, %{db: elem(db_result, 1), server: elem(server_result, 1)}}
    else
      {:error, errors}
    end
  end

  defp load_database_config(raw) do
    with {:ok, host} <- require_string(raw, :host, "database.host"),
         {:ok, port} <- optional_port(raw, :port, 5432, "database.port"),
         {:ok, database} <- require_string(raw, :database, "database.database"),
         {:ok, username} <- require_string(raw, :username, "database.username"),
         {:ok, pool_size} <- optional_positive_integer(raw, :pool_size, 10, "database.pool_size") do
      {:ok, %DatabaseConfig{
        host: host,
        port: port,
        database: database,
        username: username,
        password: Map.get(raw, :password),
        pool_size: pool_size,
        ssl: Map.get(raw, :ssl, false)
      }}
    end
  end

  defp load_server_config(raw) do
    with {:ok, host} <- optional_string(raw, :host, "0.0.0.0", "server.host"),
         {:ok, port} <- optional_port(raw, :port, 4000, "server.port"),
         {:ok, timeout} <- optional_positive_integer(raw, :request_timeout_ms, 30_000, "server.request_timeout_ms") do
      {:ok, %ServerConfig{
        host: host,
        port: port,
        http2: Map.get(raw, :http2, false),
        request_timeout_ms: timeout
      }}
    end
  end

  defp require_string(map, key, label) do
    case Map.get(map, key) do
      val when is_binary(val) and val != "" -> {:ok, val}
      nil -> {:error, ["#{label} is required"]}
      _ -> {:error, ["#{label} must be a non-empty string"]}
    end
  end

  defp optional_string(map, key, default, _label) do
    case Map.get(map, key, default) do
      val when is_binary(val) -> {:ok, val}
      _ -> {:ok, default}
    end
  end

  defp optional_port(map, key, default, label) do
    case Map.get(map, key, default) do
      val when is_integer(val) and val > 0 and val <= 65_535 -> {:ok, val}
      _ -> {:error, ["#{label} must be a valid port number (1-65535)"]}
    end
  end

  defp optional_positive_integer(map, key, default, label) do
    case Map.get(map, key, default) do
      val when is_integer(val) and val > 0 -> {:ok, val}
      _ -> {:error, ["#{label} must be a positive integer"]}
    end
  end
end
```
