```elixir
defmodule Surveys.ResponseAggregator do
  @moduledoc """
  Aggregates survey response data into per-question statistics. Supports
  single-choice, multiple-choice, rating-scale, and free-text question
  types. Each question type produces a type-specific stats map. All
  computation is pure and operates on in-memory response lists, making
  the module independent of any storage or process layer.
  """

  @type question_id :: String.t()
  @type question_type :: :single_choice | :multiple_choice | :rating | :free_text
  @type answer :: String.t() | [String.t()] | integer()

  @type response :: %{
          respondent_id: String.t(),
          answers: %{question_id() => answer()}
        }

  @type question :: %{
          id: question_id(),
          type: question_type(),
          options: [String.t()] | nil
        }

  @type single_choice_stats :: %{
          type: :single_choice,
          total: non_neg_integer(),
          counts: %{String.t() => non_neg_integer()},
          percentages: %{String.t() => float()}
        }

  @type rating_stats :: %{
          type: :rating,
          total: non_neg_integer(),
          mean: float(),
          min: integer() | nil,
          max: integer() | nil,
          distribution: %{integer() => non_neg_integer()}
        }

  @type free_text_stats :: %{
          type: :free_text,
          total: non_neg_integer(),
          responses: [String.t()]
        }

  @type question_stats :: single_choice_stats() | rating_stats() | free_text_stats()
  @type survey_report :: %{question_id() => question_stats()}

  @doc """
  Aggregates `responses` for each question in `questions`.
  Returns a map keyed by question ID with type-specific statistics.
  """
  @spec aggregate([response()], [question()]) :: survey_report()
  def aggregate(responses, questions)
      when is_list(responses) and is_list(questions) do
    Map.new(questions, fn question ->
      answers = collect_answers(responses, question.id)
      {question.id, compute_stats(question, answers)}
    end)
  end

  @doc "Returns the completion rate as a float between 0.0 and 1.0."
  @spec completion_rate([response()], [question()]) :: float()
  def completion_rate([], _questions), do: 0.0

  def completion_rate(responses, questions) when is_list(questions) do
    question_ids = Enum.map(questions, & &1.id)

    completed =
      Enum.count(responses, fn r ->
        Enum.all?(question_ids, fn qid ->
          r.answers |> Map.get(qid) |> answered?()
        end)
      end)

    Float.round(completed / length(responses), 4)
  end

  @doc "Returns the top `n` most frequent free-text answers for a question."
  @spec top_free_text([response()], question_id(), pos_integer()) :: [{String.t(), pos_integer()}]
  def top_free_text(responses, question_id, n \\ 10)
      when is_binary(question_id) and is_integer(n) and n > 0 do
    responses
    |> collect_answers(question_id)
    |> Enum.reject(&(not is_binary(&1) or String.trim(&1) == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_ans, count} -> count end, :desc)
    |> Enum.take(n)
  end

  defp collect_answers(responses, question_id) do
    Enum.flat_map(responses, fn r ->
      case Map.get(r.answers, question_id) do
        nil -> []
        answer when is_list(answer) -> answer
        answer -> [answer]
      end
    end)
  end

  defp compute_stats(%{type: :single_choice, options: options}, answers) do
    options = options || []
    counts = Map.new(options, fn opt -> {opt, 0} end)
    counts = Enum.reduce(answers, counts, fn ans, acc -> Map.update(acc, ans, 1, &(&1 + 1)) end)
    total = Enum.sum(Map.values(counts))

    percentages =
      Map.new(counts, fn {opt, count} ->
        pct = if total > 0, do: Float.round(count / total * 100, 1), else: 0.0
        {opt, pct}
      end)

    %{type: :single_choice, total: total, counts: counts, percentages: percentages}
  end

  defp compute_stats(%{type: :multiple_choice, options: options}, answers) do
    options = options || []
    counts = Map.new(options, fn opt -> {opt, 0} end)
    counts = Enum.reduce(answers, counts, fn ans, acc -> Map.update(acc, ans, 1, &(&1 + 1)) end)
    total = length(answers)

    percentages =
      Map.new(counts, fn {opt, count} ->
        pct = if total > 0, do: Float.round(count / total * 100, 1), else: 0.0
        {opt, pct}
      end)

    %{type: :multiple_choice, total: total, counts: counts, percentages: percentages}
  end

  defp compute_stats(%{type: :rating}, answers) do
    numeric = Enum.filter(answers, &is_integer/1)
    total = length(numeric)

    if total == 0 do
      %{type: :rating, total: 0, mean: 0.0, min: nil, max: nil, distribution: %{}}
    else
      mean = Float.round(Enum.sum(numeric) / total, 2)
      distribution = Enum.frequencies(numeric)
      %{type: :rating, total: total, mean: mean, min: Enum.min(numeric), max: Enum.max(numeric), distribution: distribution}
    end
  end

  defp compute_stats(%{type: :free_text}, answers) do
    texts = Enum.filter(answers, &(is_binary(&1) and String.trim(&1) != ""))
    %{type: :free_text, total: length(texts), responses: texts}
  end

  defp answered?(nil), do: false
  defp answered?([]), do: false
  defp answered?(""), do: false
  defp answered?(_), do: true
end
```
