```elixir
defmodule GraphQL.Apq.Cache do
  @moduledoc """
  Implements the Automatic Persisted Queries (APQ) protocol for GraphQL.

  APQ reduces network overhead by allowing clients to send only a SHA-256
  hash on subsequent requests after the full query has been registered.
  The cache stores query strings keyed by their hash; on a cache miss the
  client must resend the full document. The cache is backed by a public
  ETS table for concurrent reads and a GenServer for serialised writes.
  """

  use GenServer

  @table __MODULE__

  @type hash :: String.t()
  @type query_document :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec lookup(hash()) :: {:ok, query_document()} | {:error, :not_found}
  def lookup(hash) when is_binary(hash) do
    case :ets.lookup(@table, hash) do
      [{^hash, document}] -> {:ok, document}
      [] -> {:error, :not_found}
    end
  end

  @spec register(hash(), query_document()) ::
          :ok | {:error, :hash_mismatch}
  def register(hash, document) when is_binary(hash) and is_binary(document) do
    computed = compute_hash(document)

    if computed == hash do
      GenServer.call(__MODULE__, {:put, hash, document})
    else
      {:error, :hash_mismatch}
    end
  end

  @spec resolve(hash(), query_document() | nil) ::
          {:ok, query_document()}
          | {:error, :not_found}
          | {:error, :hash_mismatch}
  def resolve(hash, nil) do
    lookup(hash)
  end

  def resolve(hash, document) when is_binary(document) do
    case lookup(hash) do
      {:ok, cached} ->
        {:ok, cached}

      {:error, :not_found} ->
        case register(hash, document) do
          :ok -> {:ok, document}
          {:error, _} = err -> err
        end
    end
  end

  @spec compute_hash(query_document()) :: hash()
  def compute_hash(document) when is_binary(document) do
    :crypto.hash(:sha256, document) |> Base.encode16(case: :lower)
  end

  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl GenServer
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, 10_000)
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{max_entries: max_entries}}
  end

  @impl GenServer
  def handle_call({:put, hash, document}, _from, state) do
    if :ets.info(@table, :size) >= state.max_entries do
      evict_one()
    end

    :ets.insert(@table, {hash, document})
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp evict_one do
    case :ets.first(@table) do
      :"$end_of_table" -> :ok
      key -> :ets.delete(@table, key)
    end
  end
end
```
