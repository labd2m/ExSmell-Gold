# Annotated Example 05 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defreport/2` inside `Reporting.ReportDSL`
- **Affected function(s):** `defreport/2`
- **Short explanation:** The macro expands a large quoted block containing format validation, schedule parsing, permission scope checks, and module-attribute registration for every report declaration. All of this code is re-expanded by the compiler on each call site rather than being delegated to a function compiled once.

---

```elixir
defmodule Reporting.ReportDSL do
  @moduledoc """
  Compile-time DSL for declaring report definitions.

  Reports expose a name, supported export formats, an optional schedule,
  the required permission scopes, and a data-source reference. The DSL
  validates all parameters at compile time and registers each report
  as a module attribute.
  """

  @valid_formats [:csv, :xlsx, :pdf, :json]
  @valid_schedules [:daily, :weekly, :monthly, :on_demand]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defreport/2 inlines all validation
  # VALIDATION: (formats, schedule, scopes, data source, title) inside the
  # VALIDATION: quoted block. Every declaration expands this whole body through
  # VALIDATION: the compiler separately, rather than delegating to a
  # VALIDATION: single helper function compiled once.
  defmacro defreport(report_name, opts) do
    quote do
      report = unquote(report_name)
      opts   = unquote(opts)

      unless is_atom(report) do
        raise ArgumentError,
              "report name must be an atom, got: #{inspect(report)}"
      end

      title = Keyword.fetch!(opts, :title)

      unless is_binary(title) do
        raise ArgumentError,
              "report #{inspect(report)} :title must be a binary"
      end

      formats = Keyword.get(opts, :formats, [:csv])

      unless is_list(formats) and formats != [] do
        raise ArgumentError,
              "report #{inspect(report)} :formats must be a non-empty list"
      end

      Enum.each(formats, fn f ->
        unless f in unquote(@valid_formats) do
          raise ArgumentError,
                "report #{inspect(report)} unsupported format #{inspect(f)}. " <>
                  "Valid: #{inspect(unquote(@valid_formats))}"
        end
      end)

      schedule = Keyword.get(opts, :schedule, :on_demand)

      unless schedule in unquote(@valid_schedules) do
        raise ArgumentError,
              "report #{inspect(report)} :schedule must be one of #{inspect(unquote(@valid_schedules))}"
      end

      scopes = Keyword.get(opts, :scopes, [])

      unless is_list(scopes) and Enum.all?(scopes, &is_binary/1) do
        raise ArgumentError,
              "report #{inspect(report)} :scopes must be a list of binary strings"
      end

      data_source = Keyword.fetch!(opts, :data_source)

      unless is_atom(data_source) do
        raise ArgumentError,
              "report #{inspect(report)} :data_source must be a module atom"
      end

      paginated = Keyword.get(opts, :paginated, true)

      unless is_boolean(paginated) do
        raise ArgumentError,
              "report #{inspect(report)} :paginated must be a boolean"
      end

      max_rows = Keyword.get(opts, :max_rows, 50_000)

      unless is_integer(max_rows) and max_rows > 0 do
        raise ArgumentError,
              "report #{inspect(report)} :max_rows must be a positive integer"
      end

      @report_definitions %{
        name:        report,
        title:       title,
        formats:     formats,
        schedule:    schedule,
        scopes:      scopes,
        data_source: data_source,
        paginated:   paginated,
        max_rows:    max_rows
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Reporting.ReportDSL, only: [defreport: 2]
      Module.register_attribute(__MODULE__, :report_definitions, accumulate: true)
      @before_compile Reporting.ReportDSL
    end
  end

  defmacro __before_compile__(env) do
    reports = Module.get_attribute(env.module, :report_definitions)

    quote do
      def reports, do: unquote(Macro.escape(reports))

      def report(name) do
        Enum.find(reports(), &(&1.name == name))
      end

      def reports_for_scope(scope) do
        Enum.filter(reports(), fn r -> scope in r.scopes end)
      end

      def scheduled_reports do
        Enum.reject(reports(), &(&1.schedule == :on_demand))
      end
    end
  end
end

defmodule Reporting.AppReports do
  use Reporting.ReportDSL

  defreport(:revenue_summary,
    title: "Revenue Summary",
    formats: [:csv, :xlsx, :pdf],
    schedule: :monthly,
    scopes: ["reports:revenue"],
    data_source: Reporting.Sources.Revenue,
    paginated: false,
    max_rows: 10_000
  )

  defreport(:user_activity,
    title: "User Activity Log",
    formats: [:csv, :json],
    schedule: :daily,
    scopes: ["reports:activity"],
    data_source: Reporting.Sources.UserEvents,
    paginated: true,
    max_rows: 100_000
  )

  defreport(:inventory_snapshot,
    title: "Inventory Snapshot",
    formats: [:xlsx],
    schedule: :weekly,
    scopes: ["reports:inventory"],
    data_source: Reporting.Sources.Inventory,
    paginated: true,
    max_rows: 50_000
  )

  defreport(:outstanding_invoices,
    title: "Outstanding Invoices",
    formats: [:csv, :pdf],
    schedule: :on_demand,
    scopes: ["reports:billing"],
    data_source: Reporting.Sources.Invoices,
    paginated: true,
    max_rows: 20_000
  )

  defreport(:shipment_performance,
    title: "Shipment Performance",
    formats: [:csv, :xlsx],
    schedule: :weekly,
    scopes: ["reports:logistics"],
    data_source: Reporting.Sources.Shipments,
    paginated: true,
    max_rows: 75_000
  )
end
```
