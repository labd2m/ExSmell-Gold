```elixir
defmodule ContentStore.Entry do
  @moduledoc false

  @type t :: %__MODULE__{
          hash: String.t(),
          content: binary(),
          size: non_neg_integer(),
          content_type: String.t() | nil,
          ref_count: pos_integer(),
          stored_at: integer()
        }

  defstruct [:hash, :content, :size, :content_type, :stored_at, ref_count: 1]
end

defmodule ContentStore do
  @moduledoc """
  A content-addressable binary store keyed by SHA-256 digest.

  Identical content is stored exactly once; uploading the same bytes
  again increments a reference count rather than creating a duplicate
  entry. Callers address content by its hash, making the store
  intrinsically deduplicated and tamper-evident. Dereferencing a hash
  decrements its count and removes the entry when it reaches zero.
  """

  use GenServer

  alias ContentStore.Entry

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(binary(), String.t() | nil) :: {:ok, String.t()}
  def put(content, content_type \\ nil)
      when is_binary(content) do
    hash = digest(content)
    GenServer.call(__MODULE__, {:put, hash, content, content_type})
    {:ok, hash}
  end

  @spec get(String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(hash) when is_binary(hash) do
    case :ets.lookup(@table, hash) do
      [{^hash, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @spec fetch_content(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def fetch_content(hash) when is_binary(hash) do
    case get(hash) do
      {:ok, %Entry{content: content}} -> {:ok, content}
      {:error, :not_found} = err -> err
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(hash) when is_binary(hash) do
    :ets.member(@table, hash)
  end

  @spec deref(String.t()) :: :ok | {:error, :not_found}
  def deref(hash) when is_binary(hash) do
    GenServer.call(__MODULE__, {:deref, hash})
  end

  @spec verify(String.t()) :: :ok | {:error, :content_tampered}
  def verify(hash) when is_binary(hash) do
    case :ets.lookup(@table, hash) do
      [{^hash, %Entry{content: content}}] ->
        if digest(content) == hash, do: :ok, else: {:error, :content_tampered}

      [] ->
        {:error, :not_found}
    end
  end

  @spec stats() :: %{entries: non_neg_integer(), total_bytes: non_neg_integer(), deduplicated: non_neg_integer()}
  def stats do
    entries = :ets.tab2list(@table)
    total_bytes = Enum.sum(Enum.map(entries, fn {_, e} -> e.size end))
    deduplicated = Enum.sum(Enum.map(entries, fn {_, e} -> (e.ref_count - 1) * e.size end))
    %{entries: length(entries), total_bytes: total_bytes, deduplicated: deduplicated}
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, hash, content, content_type}, _from, state) do
    case :ets.lookup(@table, hash) do
      [{^hash, existing}] ->
        :ets.insert(@table, {hash, %{existing | ref_count: existing.ref_count + 1}})

      [] ->
        entry = %Entry{
          hash: hash,
          content: content,
          size: byte_size(content),
          content_type: content_type,
          stored_at: System.system_time(:second)
        }

        :ets.insert(@table, {hash, entry})
    end

    {:reply, :ok, state}
  end

  def handle_call({:deref, hash}, _from, state) do
    reply =
      case :ets.lookup(@table, hash) do
        [{^hash, %Entry{ref_count: 1}}] ->
          :ets.delete(@table, hash)
          :ok

        [{^hash, entry}] ->
          :ets.insert(@table, {hash, %{entry | ref_count: entry.ref_count - 1}})
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
```
