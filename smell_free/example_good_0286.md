```elixir
defmodule MyApp.Storage.ObjectStore do
  @moduledoc """
  A behaviour-backed object storage abstraction that lets application code
  remain agnostic of the underlying provider (S3, GCS, local filesystem).
  The active adapter is selected via application configuration and started
  under the application supervisor when required.

  All public functions delegate to the configured adapter so that tests can
  inject a lightweight in-memory implementation without mocking HTTP calls.
  """

  @callback put(String.t(), binary(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback get(String.t()) ::
              {:ok, binary()} | {:error, :not_found} | {:error, term()}

  @callback delete(String.t()) ::
              :ok | {:error, term()}

  @callback exists?(String.t()) :: boolean()

  @callback public_url(String.t()) :: String.t()

  @doc "Stores `content` at `key`. Returns the canonical URL on success."
  @spec put(String.t(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def put(key, content, opts \\ []) when is_binary(key) and is_binary(content) do
    adapter().put(key, content, opts)
  end

  @doc "Retrieves the object stored at `key`."
  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found} | {:error, term()}
  def get(key) when is_binary(key), do: adapter().get(key)

  @doc "Deletes the object stored at `key`."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key), do: adapter().delete(key)

  @doc "Returns `true` when an object exists at `key`."
  @spec exists?(String.t()) :: boolean()
  def exists?(key) when is_binary(key), do: adapter().exists?(key)

  @doc "Returns the public URL for the object at `key`."
  @spec public_url(String.t()) :: String.t()
  def public_url(key) when is_binary(key), do: adapter().public_url(key)

  @spec adapter() :: module()
  defp adapter do
    Application.fetch_env!(:my_app, :object_store_adapter)
  end
end

defmodule MyApp.Storage.LocalAdapter do
  @moduledoc """
  A filesystem-backed `ObjectStore` adapter for development and test
  environments. Objects are written under a configurable base directory.
  The base URL used in `public_url/1` is set via `:local_store_base_url`.
  """

  @behaviour MyApp.Storage.ObjectStore

  @base_dir Application.compile_env(:my_app, :local_store_dir, "priv/object_store")
  @base_url Application.compile_env(:my_app, :local_store_base_url, "http://localhost:4000/uploads")

  @impl MyApp.Storage.ObjectStore
  def put(key, content, _opts) do
    path = full_path(key)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok -> {:ok, public_url(key)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MyApp.Storage.ObjectStore
  def get(key) do
    path = full_path(key)

    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MyApp.Storage.ObjectStore
  def delete(key) do
    case File.rm(full_path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MyApp.Storage.ObjectStore
  def exists?(key), do: File.exists?(full_path(key))

  @impl MyApp.Storage.ObjectStore
  def public_url(key), do: "#{@base_url}/#{key}"

  @spec full_path(String.t()) :: String.t()
  defp full_path(key), do: Path.join(@base_dir, key)
end
```
