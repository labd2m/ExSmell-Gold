```elixir
defmodule Scoring.Rubric do
  @moduledoc """
  Defines a named scoring rubric as a set of weighted criteria.
  The total weight of all criteria must equal 1.0 for the rubric to be valid.
  """

  @enforce_keys [:name, :criteria]
  defstruct [:name, :criteria]

  @type criterion :: %{key: atom(), label: String.t(), weight: float(), max_score: pos_integer()}
  @type t :: %__MODULE__{name: String.t(), criteria: list(criterion())}

  @spec new(String.t(), list(criterion())) :: {:ok, t()} | {:error, atom()}
  def new(name, criteria) when is_binary(name) and is_list(criteria) do
    with :ok <- validate_weights(criteria),
         :ok <- validate_max_scores(criteria) do
      {:ok, %__MODULE__{name: name, criteria: criteria}}
    end
  end

  @spec criterion_keys(t()) :: list(atom())
  def criterion_keys(%__MODULE__{criteria: criteria}) do
    Enum.map(criteria, & &1.key)
  end

  @spec weight_for(t(), atom()) :: {:ok, float()} | {:error, :unknown_criterion}
  def weight_for(%__MODULE__{criteria: criteria}, key) when is_atom(key) do
    case Enum.find(criteria, &(&1.key == key)) do
      nil -> {:error, :unknown_criterion}
      %{weight: w} -> {:ok, w}
    end
  end

  defp validate_weights(criteria) do
    total = criteria |> Enum.map(& &1.weight) |> Enum.sum()
    if abs(total - 1.0) < 0.001, do: :ok, else: {:error, :weights_must_sum_to_one}
  end

  defp validate_max_scores(criteria) do
    all_valid = Enum.all?(criteria, fn %{max_score: s} -> is_integer(s) and s > 0 end)
    if all_valid, do: :ok, else: {:error, :invalid_max_score}
  end
end

defmodule Scoring.Submission do
  @moduledoc """
  A candidate submission containing raw scores keyed by criterion.
  """

  @enforce_keys [:id, :candidate_id, :scores]
  defstruct [:id, :candidate_id, :scores, :submitted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          candidate_id: String.t(),
          scores: %{atom() => non_neg_integer()},
          submitted_at: DateTime.t() | nil
        }

  @spec new(String.t(), String.t(), %{atom() => non_neg_integer()}) :: t()
  def new(id, candidate_id, scores)
      when is_binary(id) and is_binary(candidate_id) and is_map(scores) do
    %__MODULE__{id: id, candidate_id: candidate_id, scores: scores, submitted_at: DateTime.utc_now()}
  end
end

defmodule Scoring.Calculator do
  @moduledoc """
  Computes weighted total scores and ranks a list of submissions under a rubric.
  All scoring logic is pure — no side effects, fully testable.
  """

  alias Scoring.{Rubric, Submission}

  @type scored :: %{submission: Submission.t(), weighted_total: float(), breakdown: map()}

  @spec score(Submission.t(), Rubric.t()) :: {:ok, scored()} | {:error, atom()}
  def score(%Submission{scores: raw_scores} = submission, %Rubric{criteria: criteria}) do
    errors = validate_scores(raw_scores, criteria)

    if Enum.empty?(errors) do
      breakdown = compute_breakdown(raw_scores, criteria)
      total = breakdown |> Map.values() |> Enum.sum()
      {:ok, %{submission: submission, weighted_total: total, breakdown: breakdown}}
    else
      {:error, {:missing_criteria, errors}}
    end
  end

  @spec rank(list(Submission.t()), Rubric.t()) :: list(scored())
  def rank(submissions, %Rubric{} = rubric) when is_list(submissions) do
    submissions
    |> Enum.flat_map(fn sub ->
      case score(sub, rubric) do
        {:ok, scored} -> [scored]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(& &1.weighted_total, :desc)
  end

  defp compute_breakdown(raw_scores, criteria) do
    Map.new(criteria, fn %{key: key, weight: weight, max_score: max} ->
      raw = Map.get(raw_scores, key, 0)
      weighted = weight * (raw / max)
      {key, Float.round(weighted, 4)}
    end)
  end

  defp validate_scores(raw_scores, criteria) do
    criteria
    |> Enum.map(& &1.key)
    |> Enum.reject(&Map.has_key?(raw_scores, &1))
  end
end
```
