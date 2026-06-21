# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `CreditScoreEvaluator` module — entire GenServer structure |
| **Affected function(s)** | `evaluate/2`, `risk_band/2`, `max_credit_limit/2`, `eligibility/3` |
| **Short explanation** | Credit score evaluation is a pure computation over a financial profile map, applying scoring rules and returning a result. There is no persistent state between evaluations, no shared resource, and no scheduling requirement. Routing all loan-application evaluations through a single GenServer creates an avoidable bottleneck during peak application periods. |

```elixir
defmodule Payments.CreditScoreEvaluator do
  use GenServer

  @moduledoc """
  Evaluates creditworthiness and computes an internal credit score
  from applicant financial profiles. Used by the loan-origination
  service during the application approval pipeline.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because credit scoring is a pure function:
  # given a financial profile, it applies a weighted scoring model and
  # returns a numeric result and risk classification. No state is shared
  # between calls. During high-volume application periods all evaluations
  # are queued through one process, creating a single point of slowdown
  # with no runtime justification.

  @score_weights %{
    payment_history:       0.35,
    amounts_owed:          0.30,
    length_of_history:     0.15,
    new_credit:            0.10,
    credit_mix:            0.10
  }

  @risk_bands [
    {750, 850, :excellent},
    {700, 749, :good},
    {650, 699, :fair},
    {600, 649, :poor},
    {300, 599, :very_poor}
  ]

  @base_credit_limits %{
    excellent: 50_000,
    good:      20_000,
    fair:       8_000,
    poor:       2_500,
    very_poor:      0
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Evaluates a financial `profile` and returns `{:ok, evaluation_map}`.
  Profile keys: `:payment_history_pct`, `:utilization_pct`,
  `:history_months`, `:new_inquiries`, `:credit_mix_score`.
  """
  def evaluate(pid, profile) do
    GenServer.call(pid, {:evaluate, profile})
  end

  @doc "Returns the risk band atom for a given numeric `score`."
  def risk_band(pid, score) do
    GenServer.call(pid, {:risk_band, score})
  end

  @doc "Returns the maximum credit limit for a given numeric `score`."
  def max_credit_limit(pid, score) do
    GenServer.call(pid, {:max_credit_limit, score})
  end

  @doc """
  Returns `{:ok, :eligible | :ineligible, reason}` for a loan request
  given a profile and `requested_amount`.
  """
  def eligibility(pid, profile, requested_amount) do
    GenServer.call(pid, {:eligibility, profile, requested_amount})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:evaluate, profile}, _from, state) do
    raw_score = compute_score(profile)
    score     = trunc(Float.round(raw_score * 550 + 300, 0))
    band      = classify_band(score)
    limit     = @base_credit_limits[band]

    result = %{
      score:         score,
      risk_band:     band,
      max_limit:     limit,
      factors:       factor_breakdown(profile)
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:risk_band, score}, _from, state) do
    {:reply, {:ok, classify_band(score)}, state}
  end

  def handle_call({:max_credit_limit, score}, _from, state) do
    band  = classify_band(score)
    limit = @base_credit_limits[band]
    {:reply, {:ok, limit}, state}
  end

  def handle_call({:eligibility, profile, requested}, _from, state) do
    raw_score  = compute_score(profile)
    score      = trunc(Float.round(raw_score * 550 + 300, 0))
    band       = classify_band(score)
    max_limit  = @base_credit_limits[band]

    result =
      cond do
        band == :very_poor              -> {:ok, :ineligible, :credit_score_too_low}
        requested > max_limit           -> {:ok, :ineligible, :requested_amount_exceeds_limit}
        profile.payment_history_pct < 0.60 -> {:ok, :ineligible, :poor_payment_history}
        true                            -> {:ok, :eligible, nil}
      end

    {:reply, result, state}
  end

  ## Private helpers

  defp compute_score(%{
    payment_history_pct: ph,
    utilization_pct:     util,
    history_months:      months,
    new_inquiries:       inq,
    credit_mix_score:    mix
  }) do
    payment_score  = ph
    amounts_score  = 1.0 - min(util, 1.0)
    history_score  = min(months / 120, 1.0)
    new_score      = max(1.0 - inq * 0.1, 0.0)
    mix_score      = min(mix, 1.0)

    payment_score  * @score_weights.payment_history +
    amounts_score  * @score_weights.amounts_owed +
    history_score  * @score_weights.length_of_history +
    new_score      * @score_weights.new_credit +
    mix_score      * @score_weights.credit_mix
  end

  defp classify_band(score) do
    case Enum.find(@risk_bands, fn {low, high, _} -> score >= low and score <= high end) do
      {_, _, band} -> band
      nil          -> :very_poor
    end
  end

  defp factor_breakdown(profile) do
    %{
      payment_history: Float.round(profile.payment_history_pct * @score_weights.payment_history, 4),
      amounts_owed:    Float.round((1 - min(profile.utilization_pct, 1)) * @score_weights.amounts_owed, 4),
      history_length:  Float.round(min(profile.history_months / 120, 1) * @score_weights.length_of_history, 4),
      new_credit:      Float.round(max(1 - profile.new_inquiries * 0.1, 0) * @score_weights.new_credit, 4),
      credit_mix:      Float.round(min(profile.credit_mix_score, 1) * @score_weights.credit_mix, 4)
    }
  end

  # VALIDATION: SMELL END
end
```
