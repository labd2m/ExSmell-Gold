```elixir
defmodule Compliance.Kyc.VerificationOrchestrator do
  @moduledoc """
  Orchestrates Know Your Customer verification checks for onboarding applicants.
  Each check is run independently; results are aggregated into an overall decision.
  The orchestrator delegates to pluggable check adapters for testability.
  """

  alias Compliance.Kyc.{Applicant, VerificationResult, CheckRegistry}

  @type check_name :: :identity | :sanctions | :pep | :adverse_media | :document
  @type check_result :: {:ok, :pass | :fail | :manual_review} | {:error, String.t()}
  @type orchestration_result :: %{
          applicant_id: String.t(),
          overall_decision: :approved | :rejected | :manual_review,
          checks: %{check_name() => check_result()},
          completed_at: DateTime.t()
        }

  @required_checks ~w(identity sanctions document)a
  @advisory_checks ~w(pep adverse_media)a

  @doc """
  Runs all KYC checks for `applicant` and returns a consolidated decision.

  ## Options
    - `:registry` - module resolving check adapters (default: CheckRegistry)
    - `:timeout_ms` - per-check timeout in milliseconds (default: 10_000)
  """
  @spec run(Applicant.t(), keyword()) :: {:ok, orchestration_result()} | {:error, String.t()}
  def run(%Applicant{} = applicant, opts \\ []) do
    registry = Keyword.get(opts, :registry, CheckRegistry)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)

    with :ok <- validate_applicant(applicant) do
      all_checks = @required_checks ++ @advisory_checks
      check_results = run_checks(applicant, all_checks, registry, timeout_ms)
      decision = derive_decision(check_results)

      {:ok,
       %{
         applicant_id: applicant.id,
         overall_decision: decision,
         checks: check_results,
         completed_at: DateTime.utc_now()
       }}
    end
  end

  defp run_checks(applicant, checks, registry, timeout_ms) do
    checks
    |> Task.async_stream(
      fn check -> {check, execute_check(check, applicant, registry)} end,
      ordered: false,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn result, acc ->
      case result do
        {:ok, {check, check_result}} -> Map.put(acc, check, check_result)
        {:exit, _reason} -> acc
      end
    end)
  end

  defp execute_check(check_name, applicant, registry) do
    case registry.adapter_for(check_name) do
      {:ok, adapter} -> adapter.run(applicant)
      {:error, :no_adapter} -> {:error, "no adapter registered for #{check_name}"}
    end
  rescue
    e -> {:error, "check exception: #{Exception.message(e)}"}
  end

  defp derive_decision(check_results) do
    required_outcomes = Enum.map(@required_checks, fn c -> Map.get(check_results, c) end)
    any_required_failed = Enum.any?(required_outcomes, fn r -> r == {:ok, :fail} end)
    any_required_errored = Enum.any?(required_outcomes, fn r -> match?({:error, _}, r) end)
    any_manual = Enum.any?(Map.values(check_results), fn r -> r == {:ok, :manual_review} end)

    cond do
      any_required_failed -> :rejected
      any_required_errored -> :manual_review
      any_manual -> :manual_review
      true -> :approved
    end
  end

  defp validate_applicant(%Applicant{id: id, full_name: name, date_of_birth: dob})
       when is_binary(id) and id != "" and is_binary(name) and name != "" and
              not is_nil(dob),
       do: :ok

  defp validate_applicant(_), do: {:error, "applicant must have id, full_name, and date_of_birth"}
end
```
