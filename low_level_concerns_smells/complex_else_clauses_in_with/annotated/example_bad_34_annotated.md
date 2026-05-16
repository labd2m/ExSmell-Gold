# Annotated Example 34 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `generate_report/2`, inside the `with` expression's `else` block
- **Affected function(s):** `generate_report/2`
- **Short explanation:** Five pipeline steps each produce differently shaped errors. The single `else` block accumulates all failure cases indiscriminately, making it ambiguous which step emitted a given error pattern and increasing cognitive load during maintenance.

---

```elixir
defmodule Reporting.ReportGenerator do
  @moduledoc """
  Compiles, renders, and distributes scheduled business reports.
  """

  alias Reporting.{
    ScheduleRepo,
    DataCollector,
    ReportRenderer,
    StorageBackend,
    DistributionService
  }

  require Logger

  @doc """
  Generates and distributes a report for `report_id` using the provided `run_opts`.

  Options:
    - `:as_of` — `Date.t()` snapshot date (defaults to today)
    - `:force`  — boolean, bypass cache

  Returns `{:ok, report_url}` or a descriptive error.
  """
  @spec generate_report(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :schedule_not_found}
          | {:error, :data_unavailable, String.t()}
          | {:error, :render_failed}
          | {:error, :storage_failed}
          | {:error, :distribution_failed, list()}
  def generate_report(report_id, run_opts \\ []) do
    as_of = Keyword.get(run_opts, :as_of, Date.utc_today())
    force = Keyword.get(run_opts, :force, false)

    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses produce five
    # different error shapes ({:error, :not_found}, {:error, :data, _},
    # {:error, :render, _}, {:error, :storage, _}, {:error, :dist, _}).
    # The single else block must match all of them flat, obscuring which
    # pipeline step is responsible for any given failure.
    with {:ok, schedule}  <- ScheduleRepo.fetch(report_id),
         {:ok, dataset}   <- DataCollector.collect(schedule, as_of, force: force),
         {:ok, rendered}  <- ReportRenderer.render(schedule.template, dataset),
         {:ok, url}       <- StorageBackend.persist(report_id, as_of, rendered),
         :ok              <- DistributionService.distribute(schedule.recipients, url) do
      Logger.info("Report #{report_id} as-of #{as_of} stored at #{url}")
      {:ok, url}
    else
      {:error, :not_found} ->
        Logger.warn("Report schedule #{report_id} does not exist")
        {:error, :schedule_not_found}

      {:error, :data, source} ->
        Logger.error("Data collection failed for source: #{source}")
        {:error, :data_unavailable, source}

      {:error, :render, detail} ->
        Logger.error("Rendering error: #{inspect(detail)}")
        {:error, :render_failed}

      {:error, :storage, detail} ->
        Logger.error("Storage backend error: #{inspect(detail)}")
        {:error, :storage_failed}

      {:error, :dist, failed_recipients} ->
        Logger.warn("Distribution failed for: #{inspect(failed_recipients)}")
        {:error, :distribution_failed, failed_recipients}
    end
    # VALIDATION: SMELL END
  end
end
```
