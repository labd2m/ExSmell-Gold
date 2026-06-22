```elixir
defmodule Storage.Backend do
  @moduledoc """
  Defines the behaviour contract for pluggable object storage backends.
  Concrete adapters (S3, GCS, local filesystem) implement this behaviour,
  allowing the application to remain storage-agnostic.
  """

  @type key :: String.t()
  @type metadata :: %{content_type: String.t(), byte_size: non_neg_integer()}
  @type upload_opts :: [content_type: String.t(), acl: atom(), ttl_seconds: pos_integer() | nil]
  @type download_opts :: [range: {non_neg_integer(), non_neg_integer()} | nil]

  @callback put(key(), binary(), upload_opts()) :: {:ok, key()} | {:error, atom()}
  @callback get(key(), download_opts()) :: {:ok, binary()} | {:error, :not_found | atom()}
  @callback delete(key()) :: :ok | {:error, atom()}
  @callback exists?(key()) :: boolean()
  @callback metadata(key()) :: {:ok, metadata()} | {:error, :not_found | atom()}
  @callback presigned_url(key(), pos_integer()) :: {:ok, String.t()} | {:error, atom()}
end

defmodule Storage.LocalAdapter do
  @moduledoc """
  A filesystem-backed storage adapter for development and test environments.
  Files are stored under a configurable base directory with the object key
  used as the relative path.
  """

  @behaviour Storage.Backend

  @spec start_link(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def start_link(opts) do
    base_dir = Keyword.fetch!(opts, :base_dir)
    File.mkdir_p!(base_dir)
    {:ok, base_dir}
  end

  @impl Storage.Backend
  def put(key, data, opts) when is_binary(key) and is_binary(data) do
    base_dir = base_directory()
    path = Path.join(base_dir, key)
    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, data) do
      :ok -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Storage.Backend
  def get(key, _opts \\ []) when is_binary(key) do
    path = Path.join(base_directory(), key)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Storage.Backend
  def delete(key) when is_binary(key) do
    path = Path.join(base_directory(), key)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Storage.Backend
  def exists?(key) when is_binary(key) do
    File.exists?(Path.join(base_directory(), key))
  end

  @impl Storage.Backend
  def metadata(key) when is_binary(key) do
    path = Path.join(base_directory(), key)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        {:ok, %{content_type: "application/octet-stream", byte_size: size}}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Storage.Backend
  def presigned_url(key, _ttl_seconds) when is_binary(key) do
    {:ok, "file://#{Path.join(base_directory(), key)}"}
  end

  @spec base_directory() :: String.t()
  defp base_directory do
    Application.get_env(:storage, :local_base_dir, "/tmp/storage")
  end
end
```
