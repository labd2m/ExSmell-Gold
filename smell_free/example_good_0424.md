# File: `example_good_424.md`

```elixir
defmodule Search.SemanticRanker do
  @moduledoc """
  Ranks a set of document candidates against a query using TF-IDF
  (term frequency-inverse document frequency) scoring.

  Documents and the query are tokenised to term bags. Each candidate
  is scored by the sum of TF-IDF weights for query terms that appear
  in it. The corpus IDF table must be pre-computed and passed in, allowing
  it to be cached and reused across many ranking calls.
  """

  @type term :: String.t()
  @type doc_id :: String.t()
  @type idf_table :: %{term() => float()}

  @type document :: %{
          required(:id) => doc_id(),
          required(:text) => String.t()
        }

  @type ranked_result :: %{
          id: doc_id(),
          score: float(),
          matched_terms: [term()]
        }

  @doc """
  Ranks `candidates` by their TF-IDF relevance to `query`.

  `idf_table` maps terms to their pre-computed IDF values for the
  full corpus. Documents with a score of zero are excluded from results.

  Returns results sorted by score descending.
  """
  @spec rank(String.t(), [document()], idf_table()) :: [ranked_result()]
  def rank(query, candidates, idf_table)
      when is_binary(query) and is_list(candidates) and is_map(idf_table) do
    query_terms = tokenize(query) |> Enum.uniq()

    candidates
    |> Enum.map(&score_document(&1, query_terms, idf_table))
    |> Enum.reject(&(&1.score == 0.0))
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc """
  Builds an IDF table from a corpus of documents.

  IDF is computed as `log(N / df)` where N is the total document count
  and df is the number of documents containing each term.
  """
  @spec build_idf([document()]) :: idf_table()
  def build_idf(documents) when is_list(documents) do
    n = length(documents)

    if n == 0 do
      %{}
    else
      document_frequencies =
        Enum.reduce(documents, %{}, fn doc, acc ->
          terms = doc.text |> tokenize() |> Enum.uniq()
          Enum.reduce(terms, acc, fn term, inner -> Map.update(inner, term, 1, &(&1 + 1)) end)
        end)

      Map.new(document_frequencies, fn {term, df} ->
        {term, :math.log(n / df)}
      end)
    end
  end

  @doc """
  Computes term frequency for each token in `text`.

  Returns a map of term to its normalised frequency within the text.
  """
  @spec term_frequencies(String.t()) :: %{term() => float()}
  def term_frequencies(text) when is_binary(text) do
    terms = tokenize(text)
    total = length(terms)

    if total == 0 do
      %{}
    else
      terms
      |> Enum.reduce(%{}, fn t, acc -> Map.update(acc, t, 1, &(&1 + 1)) end)
      |> Map.new(fn {t, count} -> {t, count / total} end)
    end
  end

  defp score_document(%{id: id, text: text}, query_terms, idf_table) do
    tf_map = term_frequencies(text)

    {score, matched} =
      Enum.reduce(query_terms, {0.0, []}, fn term, {acc_score, acc_matched} ->
        tf = Map.get(tf_map, term, 0.0)
        idf = Map.get(idf_table, term, 0.0)
        tfidf = tf * idf

        if tfidf > 0.0 do
          {acc_score + tfidf, [term | acc_matched]}
        else
          {acc_score, acc_matched}
        end
      end)

    %{id: id, score: Float.round(score, 6), matched_terms: Enum.reverse(matched)}
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.map(&stem/1)
  end

  defp stem(word) do
    word
    |> String.replace(~r/ing$/, "")
    |> String.replace(~r/tion$/, "t")
    |> String.replace(~r/ed$/, "")
    |> String.replace(~r/s$/, "")
    |> case do
      "" -> word
      stemmed -> stemmed
    end
  end
end
```
