# File: `example_good_251.md`

```elixir
defmodule Storage.ObjectMetadata do
  @moduledoc """
  ETS-backed store for object storage metadata, providing fast in-process
  lookups without a round-trip to the object storage API.

  Metadata is populated on upload and invalidated on deletion. The store
  supports prefix-based listing to mirror the hierarchical namespace
  conventions used by S3-compatible backends.
  """

  use GenServer

  @table __MODULE__

  @type object_key :: String.t()
  @type metadata :: %{
          required(:key) => object_key(),
          required(:size_bytes) => non_neg_integer(),
          required(:content_type) => String.t(),
          required(:etag) => String.t(),
          required(:stored_at) => DateTime.t(),
          optional(:custom) => map()
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Stores metadata for an object key.

  Overwrites any existing entry for the same key.
  """
  @spec put(object_key(), metadata()) :: :ok
  def put(key, %{size_bytes: _, content_type: _, etag: _} = meta) when is_binary(key) do
    :ets.insert(@table, {key, Map.put(meta, :key, key)})
    :ok
  end

  @doc """
  Retrieves metadata for a specific object key.

  Returns `{:ok, metadata}` or `{:error, :not_found}`.
  """
  @spec get(object_key()) :: {:ok, metadata()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Removes metadata for an object key.

  Returns `:ok` unconditionally.
  """
  @spec delete(object_key()) :: :ok
  def delete(key) when is_binary(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns all metadata entries whose keys share the given `prefix`,
  sorted alphabetically by key.

  Useful for implementing directory-style listings.
  """
  @spec list_prefix(String.t()) :: [metadata()]
  def list_prefix(prefix) when is_binary(prefix) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {key, _meta} -> String.starts_with?(key, prefix) end)
    |> Enum.sort_by(fn {key, _meta} -> key end)
    |> Enum.map(fn {_key, meta} -> meta end)
  end

  @doc """
  Returns the total stored size in bytes across all tracked objects,
  optionally filtered to a key prefix.
  """
  @spec total_size_bytes(String.t() | nil) :: non_neg_integer()
  def total_size_bytes(prefix \\ nil) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {key, _meta} ->
      prefix == nil or String.starts_with?(key, prefix)
    end)
    |> Enum.sum_by(fn {_key, meta} -> meta.size_bytes end)
  end

  @doc """
  Returns the count of objects currently tracked.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc """
  Returns `true` when an entry exists for `key`.
  """
  @spec exists?(object_key()) :: boolean()
  def exists?(key) when is_binary(key) do
    :ets.member(@table, key)
  end

  @doc """
  Removes all entries whose stored_at timestamp is older than `before`.

  Returns the number of entries evicted.
  """
  @spec evict_before(DateTime.t()) :: non_neg_integer()
  def evict_before(%DateTime{} = before) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_key, meta} ->
      DateTime.compare(meta.stored_at, before) == :lt
    end)
    |> Enum.reduce(0, fn {key, _meta}, count ->
      :ets.delete(@table, key)
      count + 1
    end)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
```
