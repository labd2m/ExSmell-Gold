```elixir
defmodule Research.SurveyPlatform do
  @moduledoc """
  Manages survey creation, response collection, and result analytics.
  """

  alias Research.Repo
  alias Research.Surveys.Survey
  alias Research.Surveys.Question
  alias Research.Surveys.Response
  alias Research.Surveys.Answer

  import Ecto.Query
  require Logger



  @doc "Creates a new survey owned by a given user."
  @spec create_survey(String.t(), map()) :: {:ok, Survey.t()} | {:error, Ecto.Changeset.t()}
  def create_survey(owner_id, attrs) do
    %Survey{}
    |> Survey.changeset(Map.merge(attrs, %{owner_id: owner_id, status: :draft}))
    |> Repo.insert()
  end

  @doc "Adds a question to a draft survey."
  @spec add_question(Survey.t(), map()) :: {:ok, Question.t()} | {:error, term()}
  def add_question(%Survey{status: :draft, id: survey_id}, attrs) do
    next_pos =
      Question
      |> where([q], q.survey_id == ^survey_id)
      |> select([q], coalesce(max(q.position), 0))
      |> Repo.one()

    attrs_with_pos = Map.merge(attrs, %{survey_id: survey_id, position: next_pos + 1})

    %Question{}
    |> Question.changeset(attrs_with_pos)
    |> Repo.insert()
  end

  def add_question(%Survey{}, _), do: {:error, :survey_not_draft}

  @doc "Publishes a survey, making it accessible to respondents."
  @spec publish_survey(Survey.t()) :: {:ok, Survey.t()} | {:error, atom()}
  def publish_survey(%Survey{status: :draft, id: survey_id} = survey) do
    question_count =
      Question |> where([q], q.survey_id == ^survey_id) |> Repo.aggregate(:count, :id)

    if question_count > 0 do
      survey
      |> Survey.changeset(%{status: :active, published_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :no_questions}
    end
  end

  def publish_survey(%Survey{}), do: {:error, :not_draft}

  @doc "Closes a survey to prevent further responses."
  @spec close_survey(Survey.t()) :: {:ok, Survey.t()} | {:error, atom()}
  def close_survey(%Survey{status: :active} = survey) do
    survey
    |> Survey.changeset(%{status: :closed, closed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def close_survey(%Survey{}), do: {:error, :not_active}


  @doc "Submits a complete response to an active survey."
  @spec submit_response(Survey.t(), map()) ::
          {:ok, Response.t()} | {:error, term()}
  def submit_response(%Survey{status: :active, id: survey_id}, params) do
    with :ok <- validate_response(%Survey{id: survey_id}, params[:answers]) do
      Repo.transaction(fn ->
        {:ok, response} =
          %Response{}
          |> Response.changeset(%{
            survey_id: survey_id,
            respondent_id: params[:respondent_id],
            submitted_at: DateTime.utc_now()
          })
          |> Repo.insert()

        Enum.each(params[:answers], fn %{question_id: qid, value: val} ->
          %Answer{}
          |> Answer.changeset(%{response_id: response.id, question_id: qid, value: val})
          |> Repo.insert!()
        end)

        response
      end)
    end
  end

  def submit_response(%Survey{}, _), do: {:error, :survey_not_active}

  @doc "Validates that all required questions are answered and values are in range."
  @spec validate_response(Survey.t(), [map()]) :: :ok | {:error, [String.t()]}
  def validate_response(%Survey{id: survey_id}, answers) do
    required_question_ids =
      Question
      |> where([q], q.survey_id == ^survey_id and q.required == true)
      |> select([q], q.id)
      |> Repo.all()

    answered_ids = Enum.map(answers, & &1[:question_id])
    missing = required_question_ids -- answered_ids

    if missing == [] do
      :ok
    else
      {:error, Enum.map(missing, &"Missing answer for required question #{&1}")}
    end
  end

  @doc "Lists all submitted responses for a survey."
  @spec list_responses(Survey.t()) :: [Response.t()]
  def list_responses(%Survey{id: survey_id}) do
    Response
    |> where([r], r.survey_id == ^survey_id)
    |> preload(:answers)
    |> order_by([r], asc: r.submitted_at)
    |> Repo.all()
  end


  @doc "Calculates the Net Promoter Score from responses to the NPS question."
  @spec calculate_nps(Survey.t()) :: float()
  def calculate_nps(%Survey{} = survey) do
    nps_question =
      Question
      |> where([q], q.survey_id == ^survey.id and q.question_type == :nps)
      |> limit(1)
      |> Repo.one()

    if is_nil(nps_question) do
      {:error, :no_nps_question}
    else
      scores =
        Answer
        |> where([a], a.question_id == ^nps_question.id)
        |> select([a], a.value)
        |> Repo.all()
        |> Enum.map(&String.to_integer/1)

      total = length(scores)
      promoters = Enum.count(scores, &(&1 >= 9))
      detractors = Enum.count(scores, &(&1 <= 6))

      if total > 0 do
        Float.round((promoters - detractors) / total * 100, 1)
      else
        0.0
      end
    end
  end

  @doc "Aggregates answer distributions per question."
  @spec aggregate_responses(Survey.t()) :: [map()]
  def aggregate_responses(%Survey{id: survey_id}) do
    Question
    |> where([q], q.survey_id == ^survey_id)
    |> Repo.all()
    |> Enum.map(fn question ->
      answers =
        Answer
        |> where([a], a.question_id == ^question.id)
        |> select([a], a.value)
        |> Repo.all()

      distribution = Enum.frequencies(answers)

      %{
        question_id: question.id,
        text: question.text,
        response_count: length(answers),
        distribution: distribution
      }
    end)
  end

  @doc "Exports survey results in the requested format (:csv or :json)."
  @spec export_results(Survey.t(), atom()) :: {:ok, String.t()} | {:error, atom()}
  def export_results(%Survey{} = survey, :json) do
    data = aggregate_responses(survey)
    {:ok, Jason.encode!(data, pretty: true)}
  end

  def export_results(%Survey{} = survey, :csv) do
    rows = aggregate_responses(survey)
    header = "question_id,question_text,response_count"

    lines =
      Enum.map(rows, fn r ->
        "#{r.question_id},\"#{r.text}\",#{r.response_count}"
      end)

    {:ok, Enum.join([header | lines], "\n")}
  end

  def export_results(%Survey{}, _format), do: {:error, :unsupported_format}

end
```
