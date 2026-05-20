# Annotated Example — Bad Code

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `render_report/1` function, multi-clause heads
- **Affected function(s):** `render_report/1`
- **Short explanation:** Each clause head extracts `format`, `scope`, `title`, `requested_by`, `filters`, and `generated_at` from `%ReportRequest{}`. Only `format` is pattern matched and `scope` is used in a guard; `title`, `requested_by`, `filters`, and `generated_at` are used only inside the bodies. A reader inspecting any clause must sift through six fields to find the two that actually govern dispatch.

```elixir
defmodule Reporting.ReportRenderer do
  @moduledoc """
  Renders report requests in the requested output format,
  scoped by access level and enriched with metadata.
  """

  alias Reporting.{ReportRequest, PDFRenderer, CSVExporter, JSONSerializer}
  alias Reporting.{DataFetcher, AccessPolicy, AuditLog}

  @executive_scopes ~w(global regional)a

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `title`, `requested_by`, `filters`,
  # and `generated_at` are extracted in every clause head even though they
  # play no part in deciding which clause matches. Only `format` (pattern
  # matched by value) and `scope` (evaluated in a guard) determine dispatch.
  # Bundling body-only bindings into the clause heads alongside the
  # dispatch-relevant ones makes the routing logic unnecessarily opaque.

  def render_report(%ReportRequest{
        format: :pdf,
        scope: scope,
        title: title,
        requested_by: requested_by,
        filters: filters,
        generated_at: generated_at
      })
      when scope in @executive_scopes do
    :ok = AccessPolicy.require_executive!(requested_by)

    data = DataFetcher.fetch_full(scope, filters)

    pdf_bytes =
      PDFRenderer.render(%{
        title: title,
        data: data,
        generated_at: generated_at,
        requested_by: requested_by,
        watermark: "EXECUTIVE — CONFIDENTIAL"
      })

    AuditLog.record(requested_by, :pdf_executive, scope, filters)
    {:ok, :pdf, pdf_bytes}
  end

  def render_report(%ReportRequest{
        format: :pdf,
        scope: scope,
        title: title,
        requested_by: requested_by,
        filters: filters,
        generated_at: generated_at
      }) do
    data = DataFetcher.fetch_scoped(scope, filters, requested_by)

    pdf_bytes =
      PDFRenderer.render(%{
        title: title,
        data: data,
        generated_at: generated_at,
        requested_by: requested_by
      })

    AuditLog.record(requested_by, :pdf_standard, scope, filters)
    {:ok, :pdf, pdf_bytes}
  end

  def render_report(%ReportRequest{
        format: :csv,
        scope: scope,
        title: title,
        requested_by: requested_by,
        filters: filters,
        generated_at: generated_at
      })
      when scope in @executive_scopes do
    :ok = AccessPolicy.require_executive!(requested_by)

    data = DataFetcher.fetch_full(scope, filters)

    csv_bytes =
      CSVExporter.export(%{
        title: title,
        data: data,
        generated_at: generated_at,
        requested_by: requested_by,
        include_metadata: true
      })

    AuditLog.record(requested_by, :csv_executive, scope, filters)
    {:ok, :csv, csv_bytes}
  end

  def render_report(%ReportRequest{
        format: :csv,
        scope: scope,
        title: title,
        requested_by: requested_by,
        filters: filters,
        generated_at: generated_at
      }) do
    data = DataFetcher.fetch_scoped(scope, filters, requested_by)

    csv_bytes =
      CSVExporter.export(%{
        title: title,
        data: data,
        generated_at: generated_at,
        requested_by: requested_by,
        include_metadata: false
      })

    AuditLog.record(requested_by, :csv_standard, scope, filters)
    {:ok, :csv, csv_bytes}
  end

  def render_report(%ReportRequest{
        format: :json,
        scope: scope,
        title: title,
        requested_by: requested_by,
        filters: filters,
        generated_at: generated_at
      }) do
    data = DataFetcher.fetch_scoped(scope, filters, requested_by)

    json_payload =
      JSONSerializer.serialize(%{
        title: title,
        scope: scope,
        data: data,
        generated_at: generated_at,
        requested_by: requested_by
      })

    AuditLog.record(requested_by, :json, scope, filters)
    {:ok, :json, json_payload}
  end

  # VALIDATION: SMELL END

  def render_report(%ReportRequest{format: format}) do
    {:error, {:unsupported_format, format}}
  end
end
```
