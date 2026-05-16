```elixir
defmodule Reporting.ReportGenerator do
  alias Reporting.{
    ParamValidator,
    DataWarehouse,
    FilterEngine,
    TemplateRenderer,
    StorageClient,
    ReportManifest
  }

  require Logger

  @supported_formats [:pdf, :csv, :xlsx]

  def generate_report(report_type, params, requester_id) do
    with {:ok, validated_params} <- ParamValidator.validate(report_type, params),
         {:ok, raw_data} <- DataWarehouse.fetch(report_type, validated_params),
         {:ok, filtered_data} <- FilterEngine.apply(raw_data, validated_params.filters),
         {:ok, rendered} <- TemplateRenderer.render(report_type, filtered_data, validated_params),
         {:ok, storage_ref} <- StorageClient.upload(rendered, build_storage_key(report_type, requester_id)) do
      manifest_entry = %{
        report_type: report_type,
        requester_id: requester_id,
        storage_ref: storage_ref,
        generated_at: DateTime.utc_now(),
        row_count: length(filtered_data),
        format: validated_params.format
      }

      ReportManifest.record(manifest_entry)
      Logger.info("Report #{report_type} generated for requester #{requester_id}: #{storage_ref}")
      {:ok, %{storage_ref: storage_ref, manifest: manifest_entry}}
    else
      {:error, :unknown_report_type} ->
        Logger.warning("Unknown report type: #{report_type}")
        {:error, :unsupported_report_type}

      {:error, {:invalid_params, issues}} ->
        Logger.warning("Invalid report params for #{report_type}: #{inspect(issues)}")
        {:error, {:validation_error, issues}}

      {:error, :warehouse_timeout} ->
        Logger.error("Data warehouse timed out for report #{report_type}")
        {:error, :data_source_unavailable}

      {:error, :insufficient_permissions} ->
        Logger.warning("Requester #{requester_id} lacks permissions for #{report_type}")
        {:error, :access_denied}

      {:error, :filter_config_error} ->
        Logger.error("Filter configuration error for report #{report_type}")
        {:error, :report_configuration_error}

      {:error, {:render_error, reason}} ->
        Logger.error("Rendering failed for #{report_type}: #{inspect(reason)}")
        {:error, :render_failure}

      {:error, :upload_failed} ->
        Logger.error("Storage upload failed for report #{report_type}")
        {:error, :storage_error}

      {:error, reason} ->
        Logger.error("Unexpected report error (#{report_type}): #{inspect(reason)}")
        {:error, :internal_error}
    end
  end

  defp build_storage_key(report_type, requester_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "reports/#{requester_id}/#{report_type}/#{timestamp}.pdf"
  end
end
```
