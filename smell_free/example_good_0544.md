# File: `example_good_544.md`

```elixir
defmodule Search.HighlightExtractor do
  @moduledoc """
  Extracts and annotates matched query terms within document text,
  returning a list of alternating plain and highlighted fragments
  suitable for rendering in any front-end format.

  All logic is pure; no I/O occurs. The caller controls how highlighted
  fragments are ultimately serialised (HTML, Markdown, terminal ANSI, etc.)
  by pattern-matching on the returned fragment type tags.
  """

  @type fragment ::
          {:plain, String.t()}
          | {:highlight, String.t()}

  @type highlight_result :: %{
          field: atom(),
          fragments: [fragment()],
          match_count: non_neg_integer()
        }

  @doc """
  Highlights all occurrences of `query_terms` within `text`.

  Matching is case-insensitive. Overlapping matches are merged.
  Returns a list of `{:plain, text}` and `{:highlight, text}` fragments
  that, when concatenated, reproduce the original text exactly.
  """
  @spec highlight(String.t(), [String.t()]) :: [fragment()]
  def highlight(text, query_terms)
      when is_binary(text) and is_list(query_terms) do
    terms = Enum.reject(query_terms, &(String.length(&1) == 0))

    if terms == [] do
      [{:plain, text}]
    else
      ranges = find_match_ranges(text, terms)
      merged = merge_overlapping(ranges)
      build_fragments(text, merged)
    end
  end

  @doc """
  Highlights terms in multiple named fields of a record map.

  Returns one `highlight_result` per field specified.
  """
  @spec highlight_fields(map(), [atom()], [String.t()]) :: [highlight_result()]
  def highlight_fields(record, fields, query_terms)
      when is_map(record) and is_list(fields) and is_list(query_terms) do
    Enum.flat_map(fields, fn field ->
      case Map.get(record, field) do
        text when is_binary(text) ->
          fragments = highlight(text, query_terms)
          match_count = Enum.count(fragments, fn {tag, _} -> tag == :highlight end)
          [%{field: field, fragments: fragments, match_count: match_count}]

        _ ->
          []
      end
    end)
  end

  @doc """
  Extracts a plain-text snippet of up to `max_chars` characters centred
  around the first match, including surrounding context.
  """
  @spec snippet(String.t(), [String.t()], pos_integer()) :: String.t()
  def snippet(text, query_terms, max_chars \\ 200)
      when is_binary(text) and is_list(query_terms) and is_integer(max_chars) do
    terms = Enum.reject(query_terms, &(String.length(&1) == 0))

    case find_match_ranges(text, terms) do
      [] ->
        String.slice(text, 0, max_chars)

      [{start, _len} | _rest] ->
        half = div(max_chars, 2)
        snippet_start = max(start - half, 0)
        String.slice(text, snippet_start, max_chars)
    end
  end

  defp find_match_ranges(text, terms) do
    downcased = String.downcase(text)

    Enum.flat_map(terms, fn term ->
      downcased_term = String.downcase(term)
      find_all_occurrences(downcased, downcased_term, 0, [])
    end)
  end

  defp find_all_occurrences(text, term, offset, acc) do
    case :binary.match(text, term, scope: {offset, byte_size(text) - offset}) do
      :nomatch ->
        acc

      {pos, len} ->
        find_all_occurrences(text, term, pos + 1, [{pos, len} | acc])
    end
  end

  defp merge_overlapping([]), do: []

  defp merge_overlapping(ranges) do
    ranges
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce([], fn {start, len}, acc ->
      case acc do
        [] ->
          [{start, len}]

        [{prev_start, prev_len} | rest] ->
          prev_end = prev_start + prev_len
          curr_end = start + len

          if start <= prev_end do
            [{prev_start, max(prev_end, curr_end) - prev_start} | rest]
          else
            [{start, len} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp build_fragments(text, []) do
    [{:plain, text}]
  end

  defp build_fragments(text, ranges) do
    {fragments, last_pos} =
      Enum.reduce(ranges, {[], 0}, fn {start, len}, {frags, cursor} ->
        plain_part = binary_part(text, cursor, start - cursor)
        highlighted = binary_part(text, start, len)

        new_frags =
          frags
          |> then(fn f -> if plain_part != "", do: [{:plain, plain_part} | f], else: f end)
          |> then(fn f -> [{:highlight, highlighted} | f] end)

        {new_frags, start + len}
      end)

    trailing = binary_part(text, last_pos, byte_size(text) - last_pos)

    final =
      if trailing != "" do
        [{:plain, trailing} | fragments]
      else
        fragments
      end

    Enum.reverse(final)
  end
end
```
