```elixir
defmodule Ml.Features.VectorStore do
  @moduledoc """
  An ETS-backed store for named feature vectors associated with entity IDs.
  Supports nearest-neighbour lookup by cosine similarity.
  """

  use GenServer

  @table :feature_vectors

  @type entity_id :: String.t()
  @type vector :: [float()]
  @type scored :: {entity_id(), float()}

  @doc """
  Starts the VectorStore linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a feature vector for `entity_id`. Replaces any existing entry.
  Returns `{:error, reason}` if the vector is invalid.
  """
  @spec put(entity_id(), vector()) :: :ok | {:error, String.t()}
  def put(entity_id, vector) when is_binary(entity_id) and is_list(vector) do
    case validate_vector(vector) do
      :ok -> GenServer.call(__MODULE__, {:put, entity_id, vector})
      {:error, _} = err -> err
    end
  end

  @doc """
  Retrieves the stored vector for `entity_id`.
  """
  @spec fetch(entity_id()) :: {:ok, vector()} | {:error, :not_found}
  def fetch(entity_id) when is_binary(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, vec}] -> {:ok, vec}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the top `k` entities most similar to `query_vector` by cosine similarity.
  """
  @spec nearest(vector(), pos_integer()) :: {:ok, [scored()]} | {:error, String.t()}
  def nearest(query_vector, k) when is_list(query_vector) and is_integer(k) and k > 0 do
    case validate_vector(query_vector) do
      :ok ->
        results =
          :ets.tab2list(@table)
          |> Enum.map(fn {id, vec} -> {id, cosine_similarity(query_vector, vec)} end)
          |> Enum.sort_by(fn {_id, score} -> score end, :desc)
          |> Enum.take(k)

        {:ok, results}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Removes the vector for `entity_id`.
  """
  @spec delete(entity_id()) :: :ok
  def delete(entity_id) when is_binary(entity_id) do
    GenServer.cast(__MODULE__, {:delete, entity_id})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, entity_id, vector}, _from, state) do
    :ets.insert(@table, {entity_id, vector})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:delete, entity_id}, state) do
    :ets.delete(@table, entity_id)
    {:noreply, state}
  end

  defp validate_vector([]), do: {:error, "vector must not be empty"}

  defp validate_vector(vec) do
    if Enum.all?(vec, &is_float/1) do
      :ok
    else
      {:error, "vector must contain only floats"}
    end
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end
end
```
