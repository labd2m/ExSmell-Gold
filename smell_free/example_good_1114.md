```elixir
defmodule Storage.ObjectStore do
  @moduledoc """
  Behaviour and wrapper for pluggable object storage backends.
  Production deployments use S3; test environments inject a local adapter.
  Callers depend only on this module's typed API, never on the backend directly.
  """

  @type key :: String.t()
  @type content :: binary()
  @type metadata :: %{required(String.t()) => String.t()}
  @type store_result :: {:ok, key()} | {:error, term()}
  @type fetch_result :: {:ok, content(), metadata()} | {:error, :not_found | term()}

  @callback put(key(), content(), metadata()) :: store_result()
  @callback get(key()) :: fetch_result()
  @callback delete(key()) :: :ok | {:error, term()}
  @callback list(String.t()) :: {:ok, [key()]} | {:error, term()}

  @doc "Stores an object under the given key with optional metadata."
  @spec put(key(), content(), metadata()) :: store_result()
  def put(key, content, metadata \\ %{})
      when is_binary(key) and is_binary(content) and is_map(metadata) do
    adapter().put(key, content, metadata)
  end

  @doc "Retrieves an object and its metadata by key."
  @spec get(key()) :: fetch_result()
  def get(key) when is_binary(key) do
    adapter().get(key)
  end

  @doc "Removes an object by key."
  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    adapter().delete(key)
  end

  @doc "Lists all keys sharing the given prefix."
  @spec list(String.t()) :: {:ok, [key()]} | {:error, term()}
  def list(prefix) when is_binary(prefix) do
    adapter().list(prefix)
  end

  defp adapter do
    Application.fetch_env!(:my_app, __MODULE__)[:adapter]
  end
end

defmodule Storage.Adapters.Memory do
  @moduledoc "In-memory object storage adapter suitable for test environments."

  @behaviour Storage.ObjectStore

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl Storage.ObjectStore
  def put(key, content, metadata) do
    Agent.update(__MODULE__, &Map.put(&1, key, {content, metadata}))
    {:ok, key}
  end

  @impl Storage.ObjectStore
  def get(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> {:error, :not_found}
      {content, meta} -> {:ok, content, meta}
    end
  end

  @impl Storage.ObjectStore
  def delete(key) do
    Agent.update(__MODULE__, &Map.delete(&1, key))
    :ok
  end

  @impl Storage.ObjectStore
  def list(prefix) do
    keys =
      __MODULE__
      |> Agent.get(&Map.keys/1)
      |> Enum.filter(&String.starts_with?(&1, prefix))
    {:ok, keys}
  end
end
```
