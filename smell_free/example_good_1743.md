```elixir
defmodule Surveys.ResponseAggregator do
  @moduledoc """
  Aggregates survey response data into per-question statistics.

  Supports numeric (rating) questions and choice (single/multi-select)
  questions. Aggregation is a pure computation over a list of response
  records; no I/O is performed by this module.
  """

  alias Surveys.Response
  alias Surveys.Question
  alias Surveys.QuestionStats

  @type survey_id :: String.t()
  @type question_id :: String.t()
  @type aggregation :: %{question_id() => QuestionStats.t()}

  @doc """
  Aggregates a list of survey responses into per-question statistics.

  Returns a map keyed by question ID. Each value is a `QuestionStats`
  struct appropriate for the question type.
  """
  @spec aggregate([Response.t()], [Question.t()]) :: aggregation()
  def aggregate(responses, questions)
      when is_list(responses) and is_list(questions) do
    questions
    |> Map.new(&{&1.id, &1})
    |> Enum.map(fn {question_id, question} ->
      answers = extract_answers(responses, question_id)
      stats = compute_stats(question, answers)
      {question_id, stats}
    end)
    |> Map.new()
  end

  @spec extract_answers([Response.t()], question_id()) :: [term()]
  defp extract_answers(responses, question_id) do
    responses
    |> Enum.flat_map(fn response ->
      case Map.fetch(response.answers, question_id) do
        {:ok, answer} -> [answer]
        :error -> []
      end
    end)
  end

  @spec compute_stats(Question.t(), [term()]) :: QuestionStats.t()
  defp compute_stats(%Question{type: :rating} = question, answers) do
    numeric = Enum.filter(answers, &is_number/1)
    count = length(numeric)

    {mean, median, std_dev} =
      case count do
        0 ->
          {nil, nil, nil}

        _ ->
          sorted = Enum.sort(numeric)
          m = Enum.sum(sorted) / count
          med = median_value(sorted)
          sd = std_dev_value(sorted, m)
          {Float.round(m, 2), med, Float.round(sd, 2)}
      end

    %QuestionStats{
      question_id: question.id,
      question_type: :rating,
      response_count: count,
      mean: mean,
      median: median,
      std_dev: std_dev,
      distribution: nil
    }
  end

  defp compute_stats(%Question{type: type} = question, answers)
       when type in [:single_choice, :multi_choice] do
    flat_choices =
      Enum.flat_map(answers, fn
        choice when is_binary(choice) -> [choice]
        choices when is_list(choices) -> choices
        _ -> []
      end)

    count = length(flat_choices)

    distribution =
      flat_choices
      |> Enum.frequencies()
      |> Enum.map(fn {choice, freq} ->
        percentage = if count > 0, do: Float.round(freq / count * 100, 1), else: 0.0
        {choice, %{count: freq, percentage: percentage}}
      end)
      |> Map.new()

    %QuestionStats{
      question_id: question.id,
      question_type: type,
      response_count: length(answers),
      mean: nil,
      median: nil,
      std_dev: nil,
      distribution: distribution
    }
  end

  defp compute_stats(%Question{type: :open_text} = question, answers) do
    %QuestionStats{
      question_id: question.id,
      question_type: :open_text,
      response_count: length(answers),
      mean: nil,
      median: nil,
      std_dev: nil,
      distribution: nil
    }
  end

  @spec median_value([number()]) :: float()
  defp median_value(sorted) do
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      Float.round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0, 2)
    else
      Enum.at(sorted, mid) * 1.0
    end
  end

  @spec std_dev_value([number()], float()) :: float()
  defp std_dev_value(values, mean) do
    n = length(values)
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) ** 2 end) / n
    :math.sqrt(variance)
  end
end
```
