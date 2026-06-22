```elixir
defmodule Survey.ResponseAggregator do
  @moduledoc """
  Aggregates survey responses into statistical summaries per question.
  Supports numeric rating questions and multiple-choice questions.
  """

  @type question_id :: String.t()
  @type response_value :: String.t() | integer()
  @type response :: %{respondent_id: String.t(), answers: %{question_id() => response_value()}}

  @type numeric_summary :: %{
    question_id: question_id(),
    type: :numeric,
    count: non_neg_integer(),
    mean: float(),
    min: integer(),
    max: integer(),
    std_dev: float()
  }

  @type choice_summary :: %{
    question_id: question_id(),
    type: :choice,
    count: non_neg_integer(),
    distribution: %{String.t() => non_neg_integer()},
    top_choice: String.t() | nil
  }

  @type question_summary :: numeric_summary() | choice_summary()

  @spec aggregate([response()], %{question_id() => :numeric | :choice}) :: [question_summary()]
  def aggregate(responses, question_types)
      when is_list(responses) and is_map(question_types) do
    question_types
    |> Enum.map(fn {qid, type} ->
      values = collect_answers(responses, qid)
      summarize(qid, type, values)
    end)
  end

  @spec completion_rate([response()], [question_id()]) :: float()
  def completion_rate(responses, question_ids) when is_list(responses) and is_list(question_ids) do
    if Enum.empty?(responses) or Enum.empty?(question_ids) do
      0.0
    else
      total = length(responses) * length(question_ids)
      answered = count_answered(responses, question_ids)
      answered / total
    end
  end

  @spec collect_answers([response()], question_id()) :: [response_value()]
  defp collect_answers(responses, question_id) do
    responses
    |> Enum.flat_map(fn r -> Map.get(r.answers, question_id, []) |> List.wrap() end)
    |> Enum.reject(&is_nil/1)
  end

  @spec summarize(question_id(), :numeric, [response_value()]) :: numeric_summary()
  defp summarize(qid, :numeric, []) do
    %{question_id: qid, type: :numeric, count: 0, mean: 0.0, min: 0, max: 0, std_dev: 0.0}
  end

  defp summarize(qid, :numeric, values) do
    integers = Enum.map(values, &to_integer/1)
    count = length(integers)
    mean = Enum.sum(integers) / count

    %{
      question_id: qid,
      type: :numeric,
      count: count,
      mean: Float.round(mean, 2),
      min: Enum.min(integers),
      max: Enum.max(integers),
      std_dev: Float.round(std_dev(integers, mean), 2)
    }
  end

  @spec summarize(question_id(), :choice, [response_value()]) :: choice_summary()
  defp summarize(qid, :choice, []) do
    %{question_id: qid, type: :choice, count: 0, distribution: %{}, top_choice: nil}
  end

  defp summarize(qid, :choice, values) do
    strings = Enum.map(values, &to_string/1)
    distribution = Enum.frequencies(strings)
    top_choice = distribution |> Enum.max_by(fn {_, count} -> count end) |> elem(0)

    %{
      question_id: qid,
      type: :choice,
      count: length(strings),
      distribution: distribution,
      top_choice: top_choice
    }
  end

  @spec std_dev([integer()], float()) :: float()
  defp std_dev(values, mean) do
    variance =
      values
      |> Enum.map(fn v -> :math.pow(v - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(length(values))

    :math.sqrt(variance)
  end

  @spec to_integer(response_value()) :: integer()
  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)

  @spec count_answered([response()], [question_id()]) :: non_neg_integer()
  defp count_answered(responses, question_ids) do
    Enum.reduce(responses, 0, fn response, acc ->
      answered = Enum.count(question_ids, &Map.has_key?(response.answers, &1))
      acc + answered
    end)
  end
end
```
