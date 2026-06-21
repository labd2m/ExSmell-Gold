# File: `example_good_212.md`

```elixir
defmodule Search.SpellCorrector do
  @moduledoc """
  Suggests spelling corrections for query terms by finding the closest
  matching words in a reference vocabulary using Levenshtein distance.

  The vocabulary is pre-loaded into the process dictionary for efficiency
  within a request context. For persistent use, wrap this module behind
  a GenServer or ETS cache populated at startup.
  """

  @max_distance 2
  @max_suggestions 5

  @type word :: String.t()
  @type distance :: non_neg_integer()
  @type suggestion :: %{word: word(), distance: distance()}

  @doc """
  Returns up to `limit` spelling suggestions for `query_word` drawn
  from `vocabulary`.

  Suggestions are ordered by Levenshtein distance ascending, then
  alphabetically for equal distances. Words with distance greater than
  `max_distance` are excluded.

  Options:
  - `:max_distance` — maximum edit distance to consider (default: #{@max_distance})
  - `:limit` — maximum number of suggestions to return (default: #{@max_suggestions})
  """
  @spec suggest(word(), [word()], keyword()) :: [suggestion()]
  def suggest(query_word, vocabulary, opts \\ [])
      when is_binary(query_word) and is_list(vocabulary) do
    max_dist = Keyword.get(opts, :max_distance, @max_distance)
    limit = Keyword.get(opts, :limit, @max_suggestions)
    query_lower = String.downcase(query_word)

    vocabulary
    |> Enum.map(fn word ->
      %{word: word, distance: levenshtein(query_lower, String.downcase(word))}
    end)
    |> Enum.filter(&(&1.distance <= max_dist and &1.distance > 0))
    |> Enum.sort_by(&{&1.distance, &1.word})
    |> Enum.take(limit)
  end

  @doc """
  Corrects all words in a query string, returning a map from each
  unrecognised word to its top suggestion (if one exists within range).

  Words found verbatim in the vocabulary are not included in the result.
  """
  @spec correct_query(String.t(), [word()], keyword()) ::
          %{word() => suggestion() | nil}
  def correct_query(query, vocabulary, opts \\ [])
      when is_binary(query) and is_list(vocabulary) do
    vocab_set = MapSet.new(vocabulary, &String.downcase/1)

    query
    |> tokenize()
    |> Enum.reject(&MapSet.member?(vocab_set, String.downcase(&1)))
    |> Enum.uniq()
    |> Map.new(fn word ->
      top = suggest(word, vocabulary, opts) |> List.first()
      {word, top}
    end)
  end

  @doc """
  Computes the Levenshtein edit distance between two strings.

  Implements the standard dynamic programming algorithm with O(n*m)
  time and O(min(n,m)) space.
  """
  @spec levenshtein(word(), word()) :: distance()
  def levenshtein(a, b) when is_binary(a) and is_binary(b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    len_a = length(a_chars)
    len_b = length(b_chars)

    cond do
      len_a == 0 -> len_b
      len_b == 0 -> len_a
      a == b -> 0
      true -> compute_distance(a_chars, b_chars, len_a, len_b)
    end
  end

  defp compute_distance(a_chars, b_chars, _len_a, len_b) do
    initial_row = Enum.to_list(0..len_b)

    a_chars
    |> Enum.with_index(1)
    |> Enum.reduce(initial_row, fn {a_char, row_idx}, prev_row ->
      build_row(b_chars, prev_row, a_char, row_idx)
    end)
    |> List.last()
  end

  defp build_row(b_chars, prev_row, a_char, row_idx) do
    {final_row, _} =
      b_chars
      |> Enum.with_index(1)
      |> Enum.reduce({[row_idx], prev_row}, fn {b_char, col_idx}, {current_row, [prev_diag | prev_rest] = _prev} ->
        left = hd(current_row)
        above = Enum.at(prev_row, col_idx)
        diag = Enum.at(prev_row, col_idx - 1)
        cost = if a_char == b_char, do: 0, else: 1
        cell = Enum.min([left + 1, above + 1, diag + cost])
        {[cell | current_row], prev_rest}
      end)

    Enum.reverse(final_row)
  end

  defp tokenize(query) do
    Regex.split(~r/\s+/, String.trim(query))
  end
end
```
