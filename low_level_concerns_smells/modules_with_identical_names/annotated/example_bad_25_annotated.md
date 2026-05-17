# Annotated Example 25 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Reports.Generator` declarations
- **Affected functions:** `Reports.Generator.build/2`, `Reports.Generator.run_query/2`, `Reports.Generator.format_rows/2`, `Reports.Generator.export/2`, `Reports.Generator.to_csv/1`
- **Short explanation:** Two separate source files both declare `defmodule Reports.Generator`. The BEAM can load only one version of a module at a time; the file compiled last wins, silently dropping all functions defined only in the other file and breaking any report pipeline that calls them.

---

```elixir
# ── file: lib/reports/generator.ex ──────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Reports.Generator` is declared here
# and again in a second block below. BEAM retains only one definition,
# making functions from the discarded version permanently unreachable.

defmodule Reports.Generator do
  @moduledoc """
  Builds and exports business reports from the data warehouse.
  Defined in `lib/reports/generator.ex`.
  """

  alias Reports.{DataSource, Formatter, ExportBackend}
  alias Reports.Schema.ReportDefinition

  @supported_formats [:csv, :json, :xlsx]
  @default_page_size 500

  @type report_opts :: [
    format: atom(),
    page_size: pos_integer(),
    filters: map(),
    sort_by: String.t() | nil,
    sort_dir: :asc | :desc
  ]

  @doc """
  Build and immediately return a report as a formatted binary.
  `definition` is a `ReportDefinition` struct describing the data source,
  columns, and default filters.
  """
  @spec build(ReportDefinition.t(), report_opts()) ::
          {:ok, binary()} | {:error, String.t()}
  def build(%ReportDefinition{} = definition, opts \\ []) do
    format = Keyword.get(opts, :format, :csv)
    filters = Keyword.get(opts, :filters, %{})
    sort_by = Keyword.get(opts, :sort_by)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)

    unless format in @supported_formats do
      {:error, "Unsupported format: #{format}"}
    else
      with {:ok, rows} <- run_query(definition, filters),
           sorted_rows <- sort_rows(rows, sort_by, sort_dir),
           {:ok, formatted} <- format_rows(sorted_rows, format) do
        {:ok, formatted}
      end
    end
  end

  @doc "Execute the underlying data warehouse query for a report definition."
  @spec run_query(ReportDefinition.t(), map()) ::
          {:ok, [map()]} | {:error, String.t()}
  def run_query(%ReportDefinition{source: source, columns: cols}, filters) do
    query = DataSource.build_query(source, cols, filters)

    case DataSource.execute(query, page_size: @default_page_size) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, "Query failed: #{inspect(reason)}"}
    end
  end

  @doc "Serialize a list of row maps to the requested format binary."
  @spec format_rows([map()], atom()) :: {:ok, binary()} | {:error, String.t()}
  def format_rows(rows, :csv), do: Formatter.to_csv(rows)
  def format_rows(rows, :json), do: Formatter.to_json(rows)
  def format_rows(rows, :xlsx), do: Formatter.to_xlsx(rows)
  def format_rows(_rows, fmt), do: {:error, "Unknown format: #{fmt}"}

  @doc "Export a report directly to a storage backend (S3, GCS, etc.)."
  @spec export(ReportDefinition.t(), report_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def export(%ReportDefinition{name: name} = definition, opts \\ []) do
    destination = Keyword.get(opts, :destination, "reports/#{name}")

    with {:ok, binary} <- build(definition, opts),
         {:ok, url} <- ExportBackend.upload(binary, destination) do
      {:ok, url}
    end
  end

  @doc "Convert a plain list of row maps directly to a CSV binary."
  @spec to_csv([map()]) :: {:ok, binary()} | {:error, String.t()}
  def to_csv(rows) when is_list(rows) do
    case rows do
      [] ->
        {:ok, ""}

      [first | _] ->
        headers = Map.keys(first) |> Enum.join(",")

        body =
          Enum.map_join(rows, "\n", fn row ->
            Map.values(row) |> Enum.map(&to_string/1) |> Enum.join(",")
          end)

        {:ok, "#{headers}\n#{body}"}
    end
  end

  defp sort_rows(rows, nil, _dir), do: rows

  defp sort_rows(rows, field, dir) do
    Enum.sort_by(rows, &Map.get(&1, field), dir)
  end
end

# VALIDATION: SMELL END

# ── file: lib/reports/generator_scheduler.ex  (a developer added scheduling
#    helpers but forgot to create a distinct module name) ────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Reports.Generator` overwrites the first
# at load time. Any caller invoking `build/2`, `run_query/2`, `format_rows/2`,
# `export/2`, or `to_csv/1` will receive an `UndefinedFunctionError` because
# those functions only existed in the discarded first definition.

defmodule Reports.Generator do
  @moduledoc """
  Scheduled report generation and delivery management.
  Was meant to be `Reports.Generator.Scheduler` but was accidentally given
  the same module name as the core generator.
  """

  alias Reports.ScheduleStore
  alias Reports.DeliveryPolicy

  @doc "Register a report to run on a cron-like schedule."
  @spec register_schedule(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def register_schedule(report_name, cron_expression, delivery_opts) do
    with :ok <- validate_cron(cron_expression),
         {:ok, policy} <- DeliveryPolicy.from_opts(delivery_opts) do
      schedule = %{
        id: generate_id(),
        report_name: report_name,
        cron: cron_expression,
        policy: policy,
        created_at: DateTime.utc_now(),
        active: true
      }

      ScheduleStore.save(schedule)
    end
  end

  @doc "Pause an active schedule without deleting it."
  @spec pause_schedule(String.t()) :: :ok | {:error, String.t()}
  def pause_schedule(schedule_id) do
    ScheduleStore.update(schedule_id, %{active: false})
  end

  @doc "Resume a previously paused schedule."
  @spec resume_schedule(String.t()) :: :ok | {:error, String.t()}
  def resume_schedule(schedule_id) do
    ScheduleStore.update(schedule_id, %{active: true})
  end

  @doc "List all schedules, optionally filtering to active-only."
  @spec list_schedules(boolean()) :: [map()]
  def list_schedules(active_only \\ false) do
    all = ScheduleStore.all()
    if active_only, do: Enum.filter(all, & &1.active), else: all
  end

  defp validate_cron(expr) do
    parts = String.split(expr, " ")

    if length(parts) == 5,
      do: :ok,
      else: {:error, "Invalid cron expression: #{expr}"}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# VALIDATION: SMELL END
```
