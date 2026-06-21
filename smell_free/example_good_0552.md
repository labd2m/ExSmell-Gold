# File: `example_good_552.md`

```elixir
defmodule Content.TagExtractor do
  @moduledoc """
  Extracts candidate tags from plain text using TF-IDF-inspired term
  scoring, stop-word filtering, and configurable n-gram extraction.

  All operations are pure. Tags are scored by a combination of term
  frequency within the document and inverse frequency across a supplied
  reference corpus. When no corpus is provided, term frequency alone
  is used.
  """

  @type tag :: String.t()
  @type corpus_frequencies :: %{tag() => non_neg_integer()}

  @type extract_opts :: [
          max_tags: pos_integer(),
          min_chars: pos_integer(),
          ngram_sizes: [pos_integer()],
          corpus: corpus_frequencies()
        ]

  @type scored_tag :: %{tag: tag(), score: float()}

  @english_stop_words ~w(a an the and or but if in on at to for of with by is are was were be been
    being have has had do does did will would could should may might shall this that these those
    it its i me my we our you your he she him her they them their what which who whom when where
    how all some any each few more most other than then there here from up about into through
    during before after above below between out off over under again further once)

  @doc """
  Extracts and scores candidate tags from `text`.

  Returns tags sorted by score descending, capped at `:max_tags`.

  Options:
  - `:max_tags` — maximum number of tags to return (default: 10)
  - `:min_chars` — minimum tag length in characters (default: 3)
  - `:ngram_sizes` — which n-gram sizes to extract (default: `[1, 2]`)
  - `:corpus` — map of term to corpus document frequency for IDF weighting
  """
  @spec extract(String.t(), extract_opts()) :: [scored_tag()]
  def extract(text, opts \\ []) when is_binary(text) do
    max_tags = Keyword.get(opts, :max_tags, 10)
    min_chars = Keyword.get(opts, :min_chars, 3)
    ngram_sizes = Keyword.get(opts, :ngram_sizes, [1, 2])
    corpus = Keyword.get(opts, :corpus, %{})

    tokens = tokenize(text)
    ngrams = extract_ngrams(tokens, ngram_sizes)
    tf_map = compute_tf(ngrams)

    ngrams
    |> Enum.uniq()
    |> Enum.reject(&(String.length(&1) < min_chars))
    |> Enum.reject(&stop_word?/1)
    |> Enum.map(fn ngram ->
      score = compute_score(ngram, tf_map, corpus)
      %{tag: ngram, score: score}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(max_tags)
  end

  @doc """
  Returns only the tag strings from an extraction result, dropping scores.
  """
  @spec tag_strings([scored_tag()]) :: [tag()]
  def tag_strings(scored_tags) when is_list(scored_tags) do
    Enum.map(scored_tags, & &1.tag)
  end

  @doc """
  Builds a corpus frequency map from a list of documents for use as
  the `:corpus` option.

  Each document contributes one count per unique term it contains.
  """
  @spec build_corpus([String.t()]) :: corpus_frequencies()
  def build_corpus(documents) when is_list(documents) do
    Enum.reduce(documents, %{}, fn doc, acc ->
      doc
      |> tokenize()
      |> Enum.uniq()
      |> Enum.reduce(acc, fn term, inner ->
        Map.update(inner, term, 1, &(&1 + 1))
      end)
    end)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  defp extract_ngrams(tokens, sizes) do
    Enum.flat_map(sizes, fn n ->
      tokens
      |> Enum.chunk_every(n, 1, :discard)
      |> Enum.map(&Enum.join(&1, " "))
    end)
  end

  defp compute_tf(ngrams) do
    total = length(ngrams)
    if total == 0 do
      %{}
    else
      ngrams
      |> Enum.frequencies()
      |> Map.new(fn {term, count} -> {term, count / total} end)
    end
  end

  defp compute_score(ngram, tf_map, corpus) do
    tf = Map.get(tf_map, ngram, 0.0)
    idf = compute_idf(ngram, corpus)
    Float.round(tf * idf, 6)
  end

  defp compute_idf(_ngram, corpus) when map_size(corpus) == 0, do: 1.0

  defp compute_idf(ngram, corpus) do
    corpus_size = corpus |> Map.values() |> Enum.sum()
    df = Map.get(corpus, ngram, 0)
    if df == 0, do: :math.log(corpus_size + 1), else: :math.log(corpus_size / df)
  end

  defp stop_word?(term) do
    words = String.split(term, " ")
    Enum.all?(words, &(&1 in @english_stop_words))
  end
end
```
