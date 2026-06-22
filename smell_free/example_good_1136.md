```elixir
defmodule Blobstore.Adapter do
  @moduledoc """
  Behaviour contract for pluggable blob storage backends.
  Both `EtsAdapter` and `FileAdapter` implement this contract,
  allowing callers to swap implementations without changing business logic.
  """

  @type key :: String.t()
  @type blob :: binary()
  @type metadata :: %{size: non_neg_integer(), stored_at: DateTime.t(), content_type: String.t()}

  @callback put(key(), blob(), String.t()) :: :ok | {:error, String.t()}
  @callback get(key()) :: {:ok, blob()} | {:error, :not_found | String.t()}
  @callback delete(key()) :: :ok | {:error, String.t()}
  @callback stat(key()) :: {:ok, metadata()} | {:error, :not_found}
  @callback list(String.t()) :: {:ok, [key()]}
end

defmodule Blobstore.EtsAdapter do
  @moduledoc """
  In-memory blob storage adapter backed by ETS.
  Suitable for testing and ephemeral cache scenarios.
  """

  @behaviour Blobstore.Adapter

  @table :blobstore_ets_adapter

  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @impl Blobstore.Adapter
  def put(key, blob, content_type)
      when is_binary(key) and is_binary(blob) and is_binary(content_type) do
    ensure_table()
    entry = {key, blob, %{size: byte_size(blob), stored_at: DateTime.utc_now(), content_type: content_type}}
    :ets.insert(@table, entry)
    :ok
  end

  @impl Blobstore.Adapter
  def get(key) when is_binary(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, blob, _meta}] -> {:ok, blob}
      [] -> {:error, :not_found}
    end
  end

  @impl Blobstore.Adapter
  def delete(key) when is_binary(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @impl Blobstore.Adapter
  def stat(key) when is_binary(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, _blob, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  @impl Blobstore.Adapter
  def list(prefix) when is_binary(prefix) do
    ensure_table()

    keys =
      :ets.tab2list(@table)
      |> Enum.filter(fn {key, _, _} -> String.starts_with?(key, prefix) end)
      |> Enum.map(fn {key, _, _} -> key end)

    {:ok, keys}
  end
end

defmodule Blobstore.FileAdapter do
  @moduledoc """
  File-system blob storage adapter. Stores each blob as a raw binary
  file under a configurable base directory. Metadata is written as a
  sidecar `.meta` file in JSON format.
  """

  @behaviour Blobstore.Adapter

  @spec base_dir() :: String.t()
  defp base_dir, do: Application.get_env(:blobstore, :file_adapter_base_dir, "/tmp/blobstore")

  @impl Blobstore.Adapter
  def put(key, blob, content_type)
      when is_binary(key) and is_binary(blob) and is_binary(content_type) do
    path = blob_path(key)
    meta_path = meta_path(key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, blob) do
      meta = %{size: byte_size(blob), stored_at: DateTime.to_iso8601(DateTime.utc_now()), content_type: content_type}
      File.write(meta_path, Jason.encode!(meta))
      :ok
    else
      {:error, reason} -> {:error, "write failed: #{reason}"}
    end
  end

  @impl Blobstore.Adapter
  def get(key) when is_binary(key) do
    case File.read(blob_path(key)) do
      {:ok, blob} -> {:ok, blob}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, "read failed: #{reason}"}
    end
  end

  @impl Blobstore.Adapter
  def delete(key) when is_binary(key) do
    File.rm(blob_path(key))
    File.rm(meta_path(key))
    :ok
  end

  @impl Blobstore.Adapter
  def stat(key) when is_binary(key) do
    case File.read(meta_path(key)) do
      {:ok, raw} ->
        with {:ok, parsed} <- Jason.decode(raw) do
          {:ok,
           %{
             size: parsed["size"],
             stored_at: DateTime.from_iso8601(parsed["stored_at"]) |> elem(1),
             content_type: parsed["content_type"]
           }}
        end

      {:error, :enoent} ->
        {:error, :not_found}
    end
  end

  @impl Blobstore.Adapter
  def list(prefix) when is_binary(prefix) do
    dir = base_dir()

    keys =
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.reject(&String.ends_with?(&1, ".meta"))
          |> Enum.filter(&String.starts_with?(&1, prefix))

        {:error, _} ->
          []
      end

    {:ok, keys}
  end

  defp blob_path(key), do: Path.join(base_dir(), sanitize(key))
  defp meta_path(key), do: Path.join(base_dir(), sanitize(key) <> ".meta")
  defp sanitize(key), do: String.replace(key, ~r|[/\\]|, "_")
end
```
