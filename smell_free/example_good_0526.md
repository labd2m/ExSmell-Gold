```elixir
defmodule Search.Tokeniser do
  @moduledoc """
  Tokenises and normalises text for full-text search indexing. Produces
  stemmed, stop-word-filtered token lists suitable for inverted index
  construction. All functions are pure and operate on binary input so
  the module has no process dependency and is safe to call from any context.
  """

  @type token :: String.t()
  @type tokenise_opts :: [
          min_length: pos_integer(),
          stop_words: [String.t()],
          max_tokens: pos_integer() | :unlimited
        ]

  @default_min_length 2
  @default_max_tokens :unlimited

  @stop_words ~w(
    a an the and or but in on at to of for is are was were be been
    being have has had do does did will would could should may might
    it its this that these those with from by as up out so if not
    no yes i me my we our you your he she his her they them their
  )

  @doc """
  Tokenises `text` into normalised tokens. Applies lowercasing, punctuation
  removal, stop-word filtering, and minimum length enforcement.
  """
  @spec tokenise(String.t(), tokenise_opts()) :: [token()]
  def tokenise(text, opts \ []) when is_binary(text) do
    min_len = Keyword.get(opts, :min_length, @default_min_length)
    stop_words = Keyword.get(opts, :stop_words, @stop_words) |> MapSet.new()
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    tokens =
      text
      |> String.downcase()
      |> String.replace(~r/[^\w\s]/u, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(fn t -> String.length(t) < min_len or MapSet.member?(stop_words, t) end)
      |> Enum.map(&stem/1)
      |> Enum.uniq()

    case max_tokens do
      :unlimited -> tokens
      n -> Enum.take(tokens, n)
    end
  end

  @doc "Returns token frequencies for `text` as a sorted keyword list."
  @spec frequencies(String.t(), tokenise_opts()) :: [{token(), pos_integer()}]
  def frequencies(text, opts \ []) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn t ->
      stop = Keyword.get(opts, :stop_words, @stop_words) |> MapSet.new()
      String.length(t) < Keyword.get(opts, :min_length, @default_min_length) or
        MapSet.member?(stop, t)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_t, count} -> count end, :desc)
  end

  @doc "Computes the Jaccard similarity between two token sets."
  @spec jaccard(String.t(), String.t()) :: float()
  def jaccard(text_a, text_b) when is_binary(text_a) and is_binary(text_b) do
    set_a = text_a |> tokenise() |> MapSet.new()
    set_b = text_b |> tokenise() |> MapSet.new()

    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: Float.round(intersection / union, 4)
  end

  @doc "Returns true when `text` contains all tokens in `query`."
  @spec matches_all?(String.t(), String.t()) :: boolean()
  def matches_all?(text, query) when is_binary(text) and is_binary(query) do
    doc_tokens = text |> tokenise() |> MapSet.new()
    query_tokens = query |> tokenise() |> MapSet.new()
    MapSet.subset?(query_tokens, doc_tokens)
  end

  defp stem(token) when byte_size(token) <= 4, do: token

  defp stem(token) do
    token
    |> strip_suffix("tion", "t")
    |> strip_suffix("ing", "")
    |> strip_suffix("ness", "")
    |> strip_suffix("ment", "")
    |> strip_suffix("ed", "")
    |> strip_suffix("ly", "")
    |> strip_suffix("er", "")
    |> strip_suffix("es", "")
    |> strip_suffix("s", "")
  end

  defp strip_suffix(token, suffix, replacement) do
    if String.ends_with?(token, suffix) and
         String.length(token) - String.length(suffix) >= 3 do
      String.slice(token, 0, String.length(token) - String.length(suffix)) <> replacement
    else
      token
    end
  end
end
```
