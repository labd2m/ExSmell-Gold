```elixir
defmodule Embeddings.Vector do
  @moduledoc """
  A fixed-dimension float vector produced by an embedding model.
  """

  @type t :: %__MODULE__{
          values: [float()],
          dimensions: pos_integer(),
          source: String.t()
        }

  defstruct [:values, :dimensions, :source]

  @spec from_list([float()], String.t()) :: {:ok, t()} | {:error, :empty_vector}
  def from_list(values, source) when is_list(values) and is_binary(source) do
    case values do
      [] -> {:error, :empty_vector}
      _ -> {:ok, %__MODULE__{values: values, dimensions: length(values), source: source}}
    end
  end

  @spec cosine_similarity(t(), t()) :: {:ok, float()} | {:error, :dimension_mismatch}
  def cosine_similarity(%__MODULE__{dimensions: d1}, %__MODULE__{dimensions: d2})
      when d1 != d2,
      do: {:error, :dimension_mismatch}

  def cosine_similarity(%__MODULE__{values: a}, %__MODULE__{values: b}) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0 do
      {:ok, 0.0}
    else
      {:ok, dot / (mag_a * mag_b)}
    end
  end
end

defmodule Embeddings.Store do
  use GenServer

  alias Embeddings.Vector

  @moduledoc """
  An in-memory nearest-neighbour store for embedding vectors.
  Supports inserting named vectors and querying for the top-K most
  similar entries using cosine similarity.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec insert(String.t(), Vector.t()) :: :ok
  def insert(id, %Vector{} = vector) when is_binary(id) do
    GenServer.cast(__MODULE__, {:insert, id, vector})
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    GenServer.cast(__MODULE__, {:delete, id})
  end

  @spec query(Vector.t(), pos_integer()) :: {:ok, [{String.t(), float()}]}
  def query(%Vector{} = query_vector, top_k) when is_integer(top_k) and top_k > 0 do
    GenServer.call(__MODULE__, {:query, query_vector, top_k})
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_cast({:insert, id, vector}, state) do
    {:noreply, Map.put(state, id, vector)}
  end

  def handle_cast({:delete, id}, state) do
    {:noreply, Map.delete(state, id)}
  end

  @impl GenServer
  def handle_call({:query, query_vector, top_k}, _from, state) do
    scored =
      state
      |> Enum.flat_map(fn {id, vector} ->
        case Vector.cosine_similarity(query_vector, vector) do
          {:ok, score} -> [{id, score}]
          {:error, _} -> []
        end
      end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)
      |> Enum.take(top_k)

    {:reply, {:ok, scored}, state}
  end
end
```
