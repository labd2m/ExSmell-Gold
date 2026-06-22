```elixir
defmodule Survey.Responses.Aggregator do
  @moduledoc """
  Aggregates survey responses into per-question statistics.
  Supports numeric average, option frequency count, and free-text collection.
  """

  @type response :: %{question_id: String.t(), answer: term()}
  @type numeric_stats :: %{count: non_neg_integer(), sum: number(), average: float()}
  @type choice_stats :: %{count: non_neg_integer(), frequencies: %{String.t() => non_neg_integer()}}
  @type text_stats :: %{count: non_neg_integer(), answers: [String.t()]}
  @type question_stats :: {:numeric, numeric_stats()} | {:choice, choice_stats()} | {:text, text_stats()}
  @type summary :: %{String.t() => question_stats()}

  @doc """
  Aggregates a list of responses into a per-question summary map.
  Unknown answer types are silently grouped under `:text` stats.
  """
  @spec aggregate([response()]) :: {:ok, summary()}
  def aggregate(responses) when is_list(responses) do
    summary =
      responses
      |> Enum.group_by(fn r -> r.question_id end)
      |> Enum.into(%{}, fn {qid, qresponses} ->
        {qid, summarize_question(qresponses)}
      end)

    {:ok, summary}
  end

  @doc """
  Returns the aggregated statistics for a specific question ID.
  """
  @spec fetch_question(summary(), String.t()) :: {:ok, question_stats()} | {:error, :not_found}
  def fetch_question(summary, question_id) when is_map(summary) and is_binary(question_id) do
    case Map.fetch(summary, question_id) do
      {:ok, _} = result -> result
      :error -> {:error, :not_found}
    end
  end

  defp summarize_question(responses) do
    answers = Enum.map(responses, fn r -> r.answer end)

    cond do
      all_numeric?(answers) -> {:numeric, compute_numeric(answers)}
      all_strings?(answers) and short_strings?(answers) -> {:choice, compute_choice(answers)}
      true -> {:text, compute_text(answers)}
    end
  end

  defp all_numeric?(answers), do: Enum.all?(answers, &is_number/1)
  defp all_strings?(answers), do: Enum.all?(answers, &is_binary/1)

  defp short_strings?(answers) do
    Enum.all?(answers, fn a -> String.length(a) <= 100 end)
  end

  defp compute_numeric(answers) do
    count = length(answers)
    sum = Enum.sum(answers)
    average = if count > 0, do: sum / count, else: 0.0
    %{count: count, sum: sum, average: average}
  end

  defp compute_choice(answers) do
    frequencies =
      Enum.reduce(answers, %{}, fn answer, acc ->
        Map.update(acc, answer, 1, fn n -> n + 1 end)
      end)

    %{count: length(answers), frequencies: frequencies}
  end

  defp compute_text(answers) do
    string_answers =
      answers
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn s -> s == "" end)

    %{count: length(string_answers), answers: string_answers}
  end
end
```
