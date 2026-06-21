# File: `example_good_422.md`

```elixir
defmodule Content.ReadabilityScorer do
  @moduledoc """
  Computes readability metrics for plain-text content using established
  formulae: Flesch Reading Ease, Flesch-Kincaid Grade Level, and a
  simple vocabulary richness ratio.

  All functions are pure transformations over a string. No I/O occurs.
  Results can guide content editors toward appropriate complexity for
  their target audience without invoking external services.
  """

  @type score_result :: %{
          flesch_reading_ease: float(),
          flesch_kincaid_grade: float(),
          vocabulary_richness: float(),
          sentence_count: non_neg_integer(),
          word_count: non_neg_integer(),
          avg_words_per_sentence: float(),
          avg_syllables_per_word: float()
        }

  @doc """
  Computes all readability metrics for `text`.

  Returns a map of scores. For texts under 10 words the sentence-level
  metrics are unreliable; callers should check `:word_count` accordingly.
  """
  @spec score(String.t()) :: score_result()
  def score(text) when is_binary(text) do
    sentences = split_sentences(text)
    words = split_words(text)

    sentence_count = max(length(sentences), 1)
    word_count = length(words)

    syllable_counts = Enum.map(words, &count_syllables/1)
    total_syllables = Enum.sum(syllable_counts)

    avg_words = if sentence_count > 0, do: word_count / sentence_count, else: 0.0
    avg_syllables = if word_count > 0, do: total_syllables / word_count, else: 0.0

    flesh_ease = 206.835 - 1.015 * avg_words - 84.6 * avg_syllables
    fk_grade = 0.39 * avg_words + 11.8 * avg_syllables - 15.59

    unique_words = words |> Enum.map(&String.downcase/1) |> Enum.uniq() |> length()
    richness = if word_count > 0, do: unique_words / word_count, else: 0.0

    %{
      flesch_reading_ease: Float.round(flesh_ease, 2),
      flesch_kincaid_grade: Float.round(fk_grade, 2),
      vocabulary_richness: Float.round(richness, 3),
      sentence_count: sentence_count,
      word_count: word_count,
      avg_words_per_sentence: Float.round(avg_words, 2),
      avg_syllables_per_word: Float.round(avg_syllables, 2)
    }
  end

  @doc """
  Returns a human-readable label for a Flesch Reading Ease score.

  Ranges follow the standard Flesch scale.
  """
  @spec ease_label(float()) :: String.t()
  def ease_label(score) when is_float(score) or is_integer(score) do
    cond do
      score >= 90 -> "Very Easy"
      score >= 80 -> "Easy"
      score >= 70 -> "Fairly Easy"
      score >= 60 -> "Standard"
      score >= 50 -> "Fairly Difficult"
      score >= 30 -> "Difficult"
      true -> "Very Confusing"
    end
  end

  @doc """
  Returns the approximate US school grade level for a Flesch-Kincaid grade score.
  """
  @spec grade_label(float()) :: String.t()
  def grade_label(grade) when is_number(grade) do
    cond do
      grade < 1 -> "Kindergarten"
      grade <= 6 -> "Elementary (Grade #{round(grade)})"
      grade <= 8 -> "Middle School (Grade #{round(grade)})"
      grade <= 12 -> "High School (Grade #{round(grade)})"
      grade <= 16 -> "College"
      true -> "Post-Graduate"
    end
  end

  defp split_sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) == 0))
  end

  defp split_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z\s']/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) == 0))
  end

  defp count_syllables(word) do
    cleaned = word |> String.downcase() |> String.replace(~r/[^a-z]/, "")

    cond do
      String.length(cleaned) <= 3 -> 1
      true ->
        vowel_groups =
          cleaned
          |> String.replace(~r/e$/, "")
          |> String.replace(~r/[aeiou]+/, "V")
          |> String.graphemes()
          |> Enum.count(&(&1 == "V"))

        max(vowel_groups, 1)
    end
  end
end
```
