```elixir
defmodule Storage.ObjectStore do
  @moduledoc """
  Abstracts object storage behind a behaviour so the application can
  switch between S3, local disk, and in-memory test implementations
  without changing call sites. The context module routes all storage
  operations through the configured adapter.
  """

  @callback put(bucket :: String.t(), key :: String.t(), data :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback get(bucket :: String.t(), key :: String.t()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  @callback delete(bucket :: String.t(), key :: String.t()) ::
              :ok | {:error, term()}

  @callback list(bucket :: String.t(), prefix :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "Stores an object, delegating to the configured adapter."
  @spec put(String.t(), String.t(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def put(bucket, key, data, opts \ []) do
    adapter().put(bucket, key, data, opts)
  end

  @doc "Retrieves an object by bucket and key."
  @spec get(String.t(), String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(bucket, key), do: adapter().get(bucket, key)

  @doc "Deletes an object from storage."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(bucket, key), do: adapter().delete(bucket, key)

  @doc "Lists object keys under the given prefix."
  @spec list(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(bucket, prefix \ ""), do: adapter().list(bucket, prefix)

  defp adapter, do: Application.fetch_env!(:my_app, :object_store_adapter)
end

defmodule Storage.LocalDiskAdapter do
  @moduledoc "Local filesystem implementation of `Storage.ObjectStore` for development."

  @behaviour Storage.ObjectStore

  @base_dir Application.compile_env(:my_app, :local_storage_path, "tmp/object_store")

  @impl Storage.ObjectStore
  def put(bucket, key, data, _opts) do
    path = object_path(bucket, key)
    File.mkdir_p!(Path.dirname(path))
    case File.write(path, data) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Storage.ObjectStore
  def get(bucket, key) do
    case File.read(object_path(bucket, key)) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Storage.ObjectStore
  def delete(bucket, key) do
    case File.rm(object_path(bucket, key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Storage.ObjectStore
  def list(bucket, prefix) do
    dir = Path.join([@base_dir, bucket])
    case File.ls(dir) do
      {:ok, files} ->
        matching = Enum.filter(files, &String.starts_with?(&1, prefix))
        {:ok, matching}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_path(bucket, key), do: Path.join([@base_dir, bucket, key])
end
```
