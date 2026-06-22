```elixir
defmodule AppWeb.PersistedQueryStore do
  @moduledoc """
  A store for Automatic Persisted Queries (APQ), a protocol extension where
  clients send a hash of the query document instead of the full query text.

  On first request, the client sends the full document; subsequent requests
  send only the SHA-256 hash. This reduces request payload size for frequently
  used queries. Unrecognised hashes return a structured error prompting the
  client to resend the full document.
  """

  use GenServer

  @type hash :: String.t()
  @type document :: String.t()
  @type lookup_result :: {:ok, document()} | {:error, :not_found}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Looks up a persisted query document by its SHA-256 hash.
  Returns `{:ok, document}` or `{:error, :not_found}`.
  """
  @spec fetch(hash()) :: lookup_result()
  def fetch(hash) when is_binary(hash) do
    table = :persistent_term.get({__MODULE__, :table})
    case :ets.lookup(table, hash) do
      [{^hash, document}] -> {:ok, document}
      [] -> {:error, :not_found}
    end
  end

  @doc "Stores a query document under its SHA-256 hash."
  @spec persist(document()) :: {:ok, hash()} | {:error, :already_exists}
  def persist(document) when is_binary(document) do
    hash = compute_hash(document)
    GenServer.call(__MODULE__, {:persist, hash, document})
  end

  @doc "Returns the count of stored persisted queries."
  @spec count() :: non_neg_integer()
  def count do
    :persistent_term.get({__MODULE__, :table}) |> :ets.info(:size)
  end

  @doc """
  Computes the expected hash for a query document.
  Useful for clients computing the hash before sending.
  """
  @spec hash_for(document()) :: hash()
  def hash_for(document) when is_binary(document), do: compute_hash(document)

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:persisted_queries, [:set, :public, read_concurrency: true])
    :persistent_term.put({__MODULE__, :table}, table)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:persist, hash, document}, _from, %{table: table} = state) do
    case :ets.lookup(table, hash) do
      [_existing] ->
        {:reply, {:error, :already_exists}, state}

      [] ->
        :ets.insert(table, {hash, document})
        {:reply, {:ok, hash}, state}
    end
  end

  defp compute_hash(document) do
    :crypto.hash(:sha256, document) |> Base.encode16(case: :lower)
  end
end

defmodule AppWeb.Plugs.ApqHandler do
  @moduledoc """
  A Plug that implements the Automatic Persisted Queries (APQ) protocol
  for Absinthe-based GraphQL endpoints.
  """

  import Plug.Conn
  alias AppWeb.PersistedQueryStore

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, body, conn} <- read_request_body(conn),
         {:ok, params} <- Jason.decode(body),
         {:ok, conn} <- resolve_document(conn, params) do
      conn
    else
      {:error, :persisted_query_not_found} ->
        respond_not_found(conn)

      _ ->
        conn
    end
  end

  defp resolve_document(conn, %{"extensions" => %{"persistedQuery" => %{"sha256Hash" => hash}}} = params) do
    case Map.get(params, "query") do
      nil ->
        case PersistedQueryStore.fetch(hash) do
          {:ok, document} ->
            {:ok, assign(conn, :graphql_document, document)}

          {:error, :not_found} ->
            {:error, :persisted_query_not_found}
        end

      document when is_binary(document) ->
        PersistedQueryStore.persist(document)
        {:ok, assign(conn, :graphql_document, document)}
    end
  end

  defp resolve_document(conn, %{"query" => document}) when is_binary(document) do
    {:ok, assign(conn, :graphql_document, document)}
  end

  defp resolve_document(conn, _), do: {:ok, conn}

  defp read_request_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      _ -> {:error, :bad_request}
    end
  end

  defp respond_not_found(conn) do
    error = Jason.encode!(%{errors: [%{message: "PersistedQueryNotFound", extensions: %{code: "PERSISTED_QUERY_NOT_FOUND"}}]})
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, error)
    |> halt()
  end
end
```
