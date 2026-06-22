```elixir
defmodule MyApp.Ops.RunbookStore do
  @moduledoc """
  Persists runbook execution reports and exposes query functions for
  operator dashboards. Reports are written once after a runbook completes
  and are never mutated, preserving a complete immutable history of all
  operational procedures run against each environment.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Ops.{RunbookReport, RunbookStepResult}

  @type target :: String.t()

  @doc """
  Persists a runbook execution report from `MyApp.Operations.RunbookExecutor`.
  Returns `{:ok, report}` or `{:error, changeset}`.
  """
  @spec save(map()) :: {:ok, RunbookReport.t()} | {:error, Ecto.Changeset.t()}
  def save(%{target: target, steps: steps} = report_data) when is_binary(target) do
    Repo.transaction(fn ->
      with {:ok, report} <- insert_report(report_data),
           :ok <- insert_steps(report.id, steps) do
        Repo.preload(report, :step_results)
      else
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc "Returns all reports for `target`, newest first."
  @spec list_for_target(target(), keyword()) :: [RunbookReport.t()]
  def list_for_target(target, opts \\ []) when is_binary(target) do
    limit = Keyword.get(opts, :limit, 50)

    RunbookReport
    |> where([r], r.target == ^target)
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> preload(:step_results)
    |> Repo.all()
  end

  @doc "Returns the most recent report for `target`."
  @spec latest(target()) :: {:ok, RunbookReport.t()} | {:error, :not_found}
  def latest(target) when is_binary(target) do
    result =
      RunbookReport
      |> where([r], r.target == ^target)
      |> order_by([r], desc: r.started_at)
      |> limit(1)
      |> preload(:step_results)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      report -> {:ok, report}
    end
  end

  @doc "Returns pass/fail statistics for each target over the last `days` days."
  @spec success_rates(pos_integer()) :: [%{target: target(), total: non_neg_integer(), passed: non_neg_integer()}]
  def success_rates(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    RunbookReport
    |> where([r], r.started_at >= ^since)
    |> group_by([r], r.target)
    |> select([r], %{
      target: r.target,
      total: count(r.id),
      passed: filter(count(r.id), r.failed == 0)
    })
    |> order_by([r], asc: r.target)
    |> Repo.all()
  end

  @spec insert_report(map()) :: {:ok, RunbookReport.t()} | {:error, Ecto.Changeset.t()}
  defp insert_report(data) do
    %RunbookReport{}
    |> RunbookReport.changeset(%{
      target: data.target,
      started_at: data.started_at,
      finished_at: data.finished_at,
      passed: data.passed,
      failed: data.failed
    })
    |> Repo.insert()
  end

  @spec insert_steps(String.t(), [map()]) :: :ok | {:error, Ecto.Changeset.t()}
  defp insert_steps(report_id, steps) do
    results =
      Enum.map(steps, fn step ->
        %RunbookStepResult{}
        |> RunbookStepResult.changeset(%{
          report_id: report_id,
          name: step.name,
          outcome: step.outcome,
          output: step.output,
          duration_ms: step.duration_ms
        })
        |> Repo.insert()
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      {:error, cs} -> {:error, cs}
    end
  end
end
```
