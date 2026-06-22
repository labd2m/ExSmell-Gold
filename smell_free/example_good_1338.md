```elixir
defmodule Search.SemanticIndex do
  @moduledoc """
  Manages a vector-based semantic search index over document embeddings.

  Embeddings are stored as float lists and similarity is computed using
  cosine distance. Index operations are provided as pure functions over
  an explicit index struct, enabling snapshot and restore patterns.
  """

  alias Search.SemanticIndex.{Entry, SearchResult, Similarity}

  @enforce_keys [:entries]
  defstruct [:entries]

  @type embedding :: [float()]
  @type t :: %__MODULE__{entries: [Entry.t()]}

  @doc """
  Creates an empty semantic index.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{entries: []}

  @doc """
  Adds a document entry with its pre-computed embedding vector.
  """
  @spec insert(t(), String.t(), String.t(), embedding()) :: {:ok, t()} | {:error, String.t()}
  def insert(%__MODULE__{entries: entries}, doc_id, content, embedding)
      when is_binary(doc_id) and is_binary(content) and is_list(embedding) do
    with :ok <- validate_embedding(embedding) do
      entry = Entry.new(doc_id, content, embedding)
      {:ok, %__MODULE__{entries: [entry | entries]}}
    end
  end

  @doc """
  Removes all entries for the given document ID.
  """
  @spec delete(t(), String.t()) :: t()
  def delete(%__MODULE__{entries: entries}, doc_id) when is_binary(doc_id) do
    %__MODULE__{entries: Enum.reject(entries, &(&1.doc_id == doc_id))}
  end

  @doc """
  Returns the top `k` most semantically similar entries to the query embedding.
  """
  @spec search(t(), embedding(), pos_integer()) :: {:ok, [SearchResult.t()]} | {:error, String.t()}
  def search(%__MODULE__{entries: []}, _query_embedding, _k) do
    {:ok, []}
  end

  def search(%__MODULE__{entries: entries}, query_embedding, k)
      when is_list(query_embedding) and is_integer(k) and k > 0 do
    with :ok <- validate_embedding(query_embedding) do
      results =
        entries
        |> Enum.map(fn entry ->
          score = Similarity.cosine(query_embedding, entry.embedding)
          SearchResult.new(entry.doc_id, entry.content, score)
        end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(k)

      {:ok, results}
    end
  end

  @doc """
  Returns the total number of indexed entries.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: length(entries)

  @doc """
  Returns the embedding for a document ID, or nil if not found.
  """
  @spec get_embedding(t(), String.t()) :: embedding() | nil
  def get_embedding(%__MODULE__{entries: entries}, doc_id) do
    entries
    |> Enum.find(&(&1.doc_id == doc_id))
    |> case do
      nil -> nil
      entry -> entry.embedding
    end
  end

  defp validate_embedding(embedding) do
    if Enum.all?(embedding, &is_float/1) and embedding != [] do
      :ok
    else
      {:error, "embedding must be a non-empty list of floats"}
    end
  end
end

defmodule Search.SemanticIndex.Entry do
  @moduledoc false

  @enforce_keys [:doc_id, :content, :embedding, :indexed_at]
  defstruct [:doc_id, :content, :embedding, :indexed_at]

  @type t :: %__MODULE__{
          doc_id: String.t(),
          content: String.t(),
          embedding: [float()],
          indexed_at: DateTime.t()
        }

  @spec new(String.t(), String.t(), [float()]) :: t()
  def new(doc_id, content, embedding) do
    %__MODULE__{doc_id: doc_id, content: content, embedding: embedding, indexed_at: DateTime.utc_now()}
  end
end

defmodule Search.SemanticIndex.SearchResult do
  @moduledoc false

  @enforce_keys [:doc_id, :content, :score]
  defstruct [:doc_id, :content, :score]

  @type t :: %__MODULE__{doc_id: String.t(), content: String.t(), score: float()}

  @spec new(String.t(), String.t(), float()) :: t()
  def new(doc_id, content, score), do: %__MODULE__{doc_id: doc_id, content: content, score: score}
end

defmodule Search.SemanticIndex.Similarity do
  @moduledoc "Pure cosine similarity computation between two embedding vectors."

  @spec cosine([float()], [float()]) :: float()
  def cosine(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = a |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt()
    norm_b = b |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt()

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  def cosine(_, _), do: 0.0
end
```
