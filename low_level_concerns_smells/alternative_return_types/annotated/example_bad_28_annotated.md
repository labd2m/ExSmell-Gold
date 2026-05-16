# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Surveys.ResponseAggregator.aggregate/2`
- **Affected function(s):** `aggregate/2`
- **Short explanation:** The `:shape` option causes the function to return a flat map of question-id to aggregate value, a nested list of `%QuestionSummary{}` structs, or a single overall completion rate float. These are three entirely different types that cannot be consumed by shared downstream code.

---

```elixir
defmodule MyApp.Surveys.ResponseAggregator do
  @moduledoc """
  Aggregates submitted survey responses for reporting and dashboard display.
  Supports per-question breakdowns, completion metrics, and NPS computation
  for voice-of-customer and employee engagement surveys.
  """

  alias MyApp.Surveys.ResponseStore
  alias MyApp.Surveys.QuestionSummary
  alias MyApp.Surveys.NpsCalculator
  alias MyApp.Surveys.CompletionRate

  @nps_question_type :rating_0_10
  @min_responses_for_stats 5

  defstruct [
    :question_id, :question_type, :question_text,
    :response_count, :aggregate, :distribution
  ]

  def survey_meta(survey_id) do
    ResponseStore.survey_info(survey_id)
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:shape] changes the return type
  # completely: :flat returns a plain %{question_id => aggregate_value} map,
  # :detailed returns a list of %QuestionSummary{} structs (one per question),
  # and :completion returns a single float representing the completion rate.
  # All three are derived from the same underlying data, but their types are
  # incompatible. Code that iterates a list of structs will crash on a map,
  # and neither can handle a bare float.
  def aggregate(survey_id, opts \\ []) when is_list(opts) do
    shape = Keyword.get(opts, :shape, :flat)
    since = Keyword.get(opts, :since)
    segment = Keyword.get(opts, :segment)
    include_open_text = Keyword.get(opts, :include_open_text, false)

    responses =
      ResponseStore.for_survey(survey_id, since: since, segment: segment)

    questions = ResponseStore.questions_for_survey(survey_id)

    case shape do
      :flat ->
        Map.new(questions, fn q ->
          answers = Enum.flat_map(responses, &Map.get(&1.answers, q.id, []))
          {q.id, compute_aggregate(q.type, answers)}
        end)

      :detailed ->
        Enum.map(questions, fn q ->
          answers = Enum.flat_map(responses, &Map.get(&1.answers, q.id, []))

          text_samples =
            if include_open_text and q.type == :open_text do
              Enum.take(answers, 10)
            else
              []
            end

          %__MODULE__{
            question_id: q.id,
            question_type: q.type,
            question_text: q.text,
            response_count: length(answers),
            aggregate: compute_aggregate(q.type, answers),
            distribution: compute_distribution(q.type, answers),
            text_samples: text_samples
          }
        end)

      :completion ->
        CompletionRate.compute(responses, questions)
    end
  end
  # VALIDATION: SMELL END

  def nps_score(survey_id, opts \\ []) do
    since = opts[:since]
    nps_questions =
      ResponseStore.questions_for_survey(survey_id)
      |> Enum.filter(&(&1.type == @nps_question_type))

    case nps_questions do
      [] -> {:error, :no_nps_question}
      [q | _] ->
        answers =
          ResponseStore.for_survey(survey_id, since: since)
          |> Enum.flat_map(&Map.get(&1.answers, q.id, []))

        if length(answers) < @min_responses_for_stats do
          {:error, :insufficient_responses}
        else
          {:ok, NpsCalculator.compute(answers)}
        end
    end
  end

  defp compute_aggregate(:rating, answers) when answers != [] do
    Enum.sum(answers) / length(answers)
  end

  defp compute_aggregate(:multiple_choice, answers) do
    Enum.frequencies(answers)
  end

  defp compute_aggregate(:boolean, answers) do
    trues = Enum.count(answers, & &1)
    if length(answers) > 0, do: trues / length(answers), else: 0.0
  end

  defp compute_aggregate(_, _), do: nil

  defp compute_distribution(:multiple_choice, answers), do: Enum.frequencies(answers)
  defp compute_distribution(:rating, answers) do
    Enum.group_by(answers, & &1) |> Map.new(fn {k, v} -> {k, length(v)} end)
  end
  defp compute_distribution(_, _), do: %{}
end
```
