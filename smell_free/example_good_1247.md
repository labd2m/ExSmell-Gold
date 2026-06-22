```elixir
defmodule Genomics.Sequences.KmerIndex do
  @moduledoc """
  Builds and queries a k-mer index over DNA sequences.
  A k-mer is a substring of length k; the index maps each k-mer to the
  sequence IDs in which it appears. All sequences must contain only valid
  IUPAC nucleotide characters.
  """

  @type sequence_id :: String.t()
  @type kmer :: String.t()
  @type index :: %{kmer() => MapSet.t(sequence_id())}

  @valid_bases ~w(A T G C N a t g c n)

  @doc """
  Builds a k-mer index from a list of `{id, sequence}` pairs.
  Returns `{:ok, index}` or `{:error, reason}` on invalid sequences.
  """
  @spec build([{sequence_id(), String.t()}], pos_integer()) ::
          {:ok, index()} | {:error, String.t()}
  def build(sequences, k) when is_list(sequences) and is_integer(k) and k > 0 do
    Enum.reduce_while(sequences, {:ok, %{}}, fn {id, seq}, {:ok, acc} ->
      case index_sequence(acc, id, seq, k) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Queries the index for all sequence IDs containing `kmer`.
  """
  @spec query(index(), kmer()) :: {:ok, [sequence_id()]} | {:error, :not_found}
  def query(index, kmer) when is_map(index) and is_binary(kmer) do
    case Map.fetch(index, String.upcase(kmer)) do
      {:ok, ids} -> {:ok, MapSet.to_list(ids)}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Returns the total number of distinct k-mers in the index.
  """
  @spec kmer_count(index()) :: non_neg_integer()
  def kmer_count(index) when is_map(index), do: map_size(index)

  @doc """
  Returns the k-mers shared between two sequence IDs in the index.
  """
  @spec shared_kmers(index(), sequence_id(), sequence_id()) :: [kmer()]
  def shared_kmers(index, id_a, id_b)
      when is_map(index) and is_binary(id_a) and is_binary(id_b) do
    index
    |> Enum.filter(fn {_kmer, ids} ->
      MapSet.member?(ids, id_a) and MapSet.member?(ids, id_b)
    end)
    |> Enum.map(fn {kmer, _} -> kmer end)
  end

  defp index_sequence(acc, id, seq, k) do
    with :ok <- validate_sequence(seq) do
      upper = String.upcase(seq)

      updated =
        extract_kmers(upper, k)
        |> Enum.reduce(acc, fn kmer, index ->
          Map.update(index, kmer, MapSet.new([id]), fn ids -> MapSet.put(ids, id) end)
        end)

      {:ok, updated}
    end
  end

  defp validate_sequence(seq) when is_binary(seq) and seq != "" do
    invalid = seq |> String.graphemes() |> Enum.find(fn c -> c not in @valid_bases end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid nucleotide character: #{inspect(invalid)}"}
    end
  end

  defp validate_sequence(_), do: {:error, "sequence must be a non-empty string"}

  defp extract_kmers(seq, k) do
    len = String.length(seq)

    if len < k do
      []
    else
      Enum.map(0..(len - k), fn i -> String.slice(seq, i, k) end)
    end
  end
end
```
