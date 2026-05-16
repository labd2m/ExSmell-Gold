# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `interpret_export_response/2` function
- **Affected function(s):** `interpret_export_response/2`
- **Short explanation:** The function is the sole handler for every possible response variant from a single analytics export API endpoint. It handles success states (completed, still processing, queued), client errors (invalid parameters, quota exceeded, unsupported format), and server-side failures — all within one deeply branched `case` expression. This makes the function long, hard to test in isolation, and fragile: any runtime error in one branch (e.g., a missing key in the body) raises an exception that prevents all other branches from being evaluated.

---

```elixir
defmodule Reporting.AnalyticsExportClient do
  @moduledoc """
  HTTP client for the internal analytics platform's async export API.
  Supports requesting, polling, and downloading scheduled data exports.
  """

  require Logger

  @base_url "https://analytics.internal/api/v1"
  @poll_interval_ms 5_000
  @max_poll_attempts 60

  def request_export(report_type, date_range, format, opts \\ []) do
    filters = Keyword.get(opts, :filters, %{})
    notify_email = Keyword.get(opts, :notify_email)

    payload = %{
      report_type: report_type,
      date_from: date_range.from,
      date_to: date_range.to,
      format: format,
      filters: filters,
      notify_email: notify_email
    }

    headers = auth_headers()

    case http_post("#{@base_url}/exports", payload, headers) do
      {:ok, raw} ->
        interpret_export_response(raw, %{action: :request, report_type: report_type})

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def poll_export(export_id) do
    poll_loop(export_id, 0)
  end

  def download_export(download_url, dest_path) do
    case http_get(download_url, auth_headers()) do
      {:ok, %{status: 200, body: binary}} ->
        File.write(dest_path, binary)

      {:ok, %{status: 403}} ->
        {:error, :download_link_expired}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_download_status, status}}

      {:error, reason} ->
        {:error, {:download_transport_error, reason}}
    end
  end

  defp poll_loop(_export_id, attempt) when attempt >= @max_poll_attempts do
    {:error, :export_poll_timeout}
  end

  defp poll_loop(export_id, attempt) do
    headers = auth_headers()

    case http_get("#{@base_url}/exports/#{export_id}", headers) do
      {:ok, raw} ->
        case interpret_export_response(raw, %{action: :poll, export_id: export_id}) do
          {:ok, %{status: :completed} = result} ->
            {:ok, result}

          {:ok, %{status: status}} when status in [:queued, :processing] ->
            Logger.debug("Export #{export_id} still #{status}, attempt #{attempt + 1}")
            Process.sleep(@poll_interval_ms)
            poll_loop(export_id, attempt + 1)

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `interpret_export_response/2` assumes
  # sole responsibility for every possible HTTP response variant from a single
  # async export API endpoint. The outer `case` on HTTP status expands into
  # nested `case` blocks on body fields for the 200 success path (three distinct
  # status sub-states with different required keys) and separate arms for quota
  # errors, format errors, validation errors, auth errors, and server failures.
  # This produces a cyclomatic complexity far above what a single private helper
  # should carry. A missing key in any one body pattern (e.g., "download_url"
  # absent when status is "completed") will raise a MatchError and crash the
  # function for all callers — regardless of which response type they sent.
  defp interpret_export_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "completed",
            "export_id" => eid,
            "download_url" => url,
            "expires_at" => exp,
            "row_count" => rows,
            "size_bytes" => size
          } ->
            {:ok,
             %{
               status: :completed,
               export_id: eid,
               download_url: url,
               expires_at: exp,
               row_count: rows,
               size_bytes: size
             }}

          %{"status" => "completed", "export_id" => eid, "download_url" => url} ->
            {:ok,
             %{
               status: :completed,
               export_id: eid,
               download_url: url,
               expires_at: nil,
               row_count: nil,
               size_bytes: nil
             }}

          %{
            "status" => "processing",
            "export_id" => eid,
            "progress_pct" => pct,
            "estimated_completion" => eta
          } ->
            {:ok,
             %{status: :processing, export_id: eid, progress_pct: pct, estimated_completion: eta}}

          %{"status" => "processing", "export_id" => eid} ->
            {:ok, %{status: :processing, export_id: eid, progress_pct: nil, estimated_completion: nil}}

          %{"status" => "queued", "export_id" => eid, "queue_position" => pos} ->
            {:ok, %{status: :queued, export_id: eid, queue_position: pos}}

          %{"status" => "queued", "export_id" => eid} ->
            {:ok, %{status: :queued, export_id: eid, queue_position: nil}}

          %{"status" => "failed", "export_id" => eid, "failure_reason" => reason} ->
            Logger.error("Export failed export_id=#{eid} reason=#{reason} context=#{inspect(context)}")
            {:error, {:export_failed, reason}}

          %{"status" => "failed"} ->
            {:error, :export_failed}

          %{"status" => unknown} ->
            {:error, {:unknown_export_status, unknown}}

          _ ->
            {:error, :malformed_response_body}
        end

      %{status: 201, body: %{"export_id" => eid, "status" => "queued"}} ->
        Logger.info("Export created export_id=#{eid} context=#{inspect(context)}")
        {:ok, %{status: :queued, export_id: eid, queue_position: nil}}

      %{status: 400, body: %{"error" => "invalid_date_range", "detail" => detail}} ->
        {:error, {:invalid_date_range, detail}}

      %{status: 400, body: %{"error" => "invalid_filters", "fields" => fields}} ->
        {:error, {:invalid_filters, fields}}

      %{status: 400, body: %{"error" => "unsupported_format", "supported" => fmts}} ->
        {:error, {:unsupported_format, fmts}}

      %{status: 400, body: %{"error" => msg}} ->
        {:error, {:bad_request, msg}}

      %{status: 400} ->
        {:error, :bad_request}

      %{status: 401} ->
        Logger.error("Unauthorized analytics API call context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "quota_exceeded", "reset_at" => reset}} ->
        {:error, {:quota_exceeded, reset}}

      %{status: 403, body: %{"error" => "plan_restriction", "upgrade_url" => url}} ->
        {:error, {:plan_restriction, url}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 404} ->
        {:error, :export_not_found}

      %{status: 409, body: %{"error" => "duplicate_export", "existing_id" => eid}} ->
        {:error, {:duplicate_export, eid}}

      %{status: 429, body: %{"retry_after" => seconds}} ->
        {:error, {:rate_limited, seconds}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"incident_id" => iid}} ->
        Logger.error("Analytics platform 500 incident_id=#{iid} context=#{inspect(context)}")
        {:error, {:server_error, iid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 502} ->
        {:error, :bad_gateway}

      %{status: 503, body: %{"maintenance_until" => ts}} ->
        {:error, {:maintenance, ts}}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning(
          "Unhandled analytics response status=#{status} body=#{inspect(body)} context=#{inspect(context)}"
        )
        {:error, {:unhandled_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp auth_headers do
    token = System.get_env("ANALYTICS_API_TOKEN", "")
    [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
  end

  defp http_get(_url, _headers), do: {:error, :not_implemented}
  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
