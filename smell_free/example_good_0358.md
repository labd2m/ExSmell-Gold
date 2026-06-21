```elixir
defmodule Content.ReadingTimeEstimator do
  @moduledoc """
  Estimates reading time and reading-level metrics for a piece of text
  content. All functions are pure and operate on binary input. Estimates
  use configurable words-per-minute rates for different reader profiles.
  The module also extracts structural statistics used by editorial tooling.
  """

  @type reader_profile :: :slow | :average | :fast
  @type estimate :: %{
          word_count: non_neg_integer(),
          sentence_count: non_neg_integer(),
          paragraph_count: non_neg_integer(),
          minutes: float(),
          profile: reader_profile()
        }

  @wpm %{slow: 150, average: 238, fast: 350}
  @sentence_end_pattern ~r/[.!?]+\s/
  @word_pattern ~r/\w+/u

  @doc """
  Estimates reading time for `text` using the given `profile`.
  Returns a map with word count, sentence count, paragraph count,
  and estimated minutes.
  """
  @spec estimate(String.t(), reader_profile()) :: estimate()
  def estimate(text, profile \ :average)
      when is_binary(text) and profile in [:slow, :average, :fast] do
    words = count_words(text)
    wpm = Map.fetch!(@wpm, profile)
    minutes = if words == 0, do: 0.0, else: Float.round(words / wpm, 1)

    %{
      word_count: words,
      sentence_count: count_sentences(text),
      paragraph_count: count_paragraphs(text),
      minutes: minutes,
      profile: profile
    }
  end

  @doc "Returns the Flesch-Kincaid reading ease score for `text` (0–100, higher is easier)."
  @spec flesch_kincaid_ease(String.t()) :: float()
  def flesch_kincaid_ease(text) when is_binary(text) do
    words = count_words(text)
    sentences = count_sentences(text)
    syllables = count_syllables(text)

    if words == 0 or sentences == 0 do
      0.0
    else
      score = 206.835 - 1.015 * (words / sentences) - 84.6 * (syllables / words)
      score |> max(0.0) |> min(100.0) |> Float.round(1)
    end
  end

  @doc "Returns the top `n` most frequent meaningful words in `text`."
  @spec top_keywords(String.t(), pos_integer()) :: [{String.t(), non_neg_integer()}]
  def top_keywords(text, n \ 10) when is_binary(text) and is_integer(n) and n > 0 do
    stop_words = stop_word_set()

    text
    |> String.downcase()
    |> then(&Regex.scan(@word_pattern, &1))
    |> List.flatten()
    |> Enum.reject(fn w -> w in stop_words or String.length(w) < 3 end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_w, count} -> count end, :desc)
    |> Enum.take(n)
  end

  defp count_words(text) do
    Regex.scan(@word_pattern, text) |> length()
  end

  defp count_sentences(text) do
    count = Regex.scan(@sentence_end_pattern, text) |> length()
    max(count, 1)
  end

  defp count_paragraphs(text) do
    text
    |> String.split(~r/
{2,}/)
    |> Enum.count(fn p -> String.trim(p) != "" end)
    |> max(1)
  end

  defp count_syllables(text) do
    text
    |> String.downcase()
    |> String.split(~r/\s+/)
    |> Enum.sum_by(&word_syllables/1)
  end

  defp word_syllables(word) do
    cleaned = String.replace(word, ~r/[^a-z]/, "")
    count = cleaned |> String.graphemes() |> Enum.count(fn c -> c in ~w(a e i o u) end)
    max(count, 1)
  end

  defp stop_word_set do
    MapSet.new(~w(the a an and or but in on at to of for is are was were be been
                  being have has had do does did will would could should may might
                  shall can it its this that these those with from by as up out))
  end
end
```
