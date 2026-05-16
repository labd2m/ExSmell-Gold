```elixir
defmodule MyApp.CRM.CRMClient do
  @moduledoc """
  Client for the external CRM system REST API.
  Handles contact creation, updates, deduplication, and sync status tracking.
  """

  require Logger

  alias MyApp.CRM.{ContactRecord, SyncLog, DuplicateResolver, FieldMapper}
  alias MyApp.Notifications.AlertDispatcher

  @api_base "https://api.crmplatform.io/v4"
  @http_timeout_ms 10_000

  @spec upsert_contact(String.t(), map()) ::
          {:ok, map()} | {:error, atom() | map()}
  def upsert_contact(workspace_id, contact_attrs) do
    headers = build_headers(workspace_id)
    mapped_attrs = FieldMapper.to_crm_schema(contact_attrs)
    body = Jason.encode!(mapped_attrs)

    Logger.debug("Upserting CRM contact: email=#{contact_attrs[:email]} workspace=#{workspace_id}")

    case HTTPoison.post("#{@api_base}/contacts/upsert", body, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        crm_id = parsed["id"]
        ContactRecord.link_crm_id(contact_attrs[:internal_id], crm_id)
        SyncLog.record(workspace_id, contact_attrs[:internal_id], :created, crm_id)
        Logger.info("CRM contact created: crm_id=#{crm_id} workspace=#{workspace_id}")
        {:ok, %{crm_id: crm_id, action: :created}}

      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        crm_id = parsed["id"]
        SyncLog.record(workspace_id, contact_attrs[:internal_id], :updated, crm_id)
        Logger.debug("CRM contact updated: crm_id=#{crm_id} workspace=#{workspace_id}")
        {:ok, %{crm_id: crm_id, action: :updated}}

      {:ok, %HTTPoison.Response{status_code: 207, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        primary_id = parsed["primary_id"]
        merged_ids = parsed["merged_ids"]
        DuplicateResolver.record_merge(primary_id, merged_ids, workspace_id)
        SyncLog.record(workspace_id, contact_attrs[:internal_id], :merged, primary_id)
        Logger.info("CRM contact merged: primary=#{primary_id} merged=#{inspect(merged_ids)}")
        {:ok, %{crm_id: primary_id, action: :merged, merged_ids: merged_ids}}

      {:ok, %HTTPoison.Response{status_code: 400, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["error_type"] do
          "VALIDATION_ERROR" ->
            field_errors = parsed["field_errors"]
            Logger.warning("CRM validation error: #{inspect(field_errors)} workspace=#{workspace_id}")

            cond do
              Map.has_key?(field_errors, "email") ->
                {:error, {:invalid_field, :email, field_errors["email"]}}

              Map.has_key?(field_errors, "phone") ->
                {:error, {:invalid_field, :phone, field_errors["phone"]}}

              Map.has_key?(field_errors, "website") ->
                {:error, {:invalid_field, :website, field_errors["website"]}}

              true ->
                {:error, {:validation_failed, field_errors}}
            end

          "FIELD_MAPPING_CONFLICT" ->
            conflicting_field = parsed["field"]
            Logger.error("CRM field mapping conflict: #{conflicting_field} workspace=#{workspace_id}")
            FieldMapper.clear_cache(workspace_id)
            {:error, {:field_mapping_conflict, conflicting_field}}

          "INVALID_LIFECYCLE_STAGE" ->
            Logger.warning("CRM invalid lifecycle stage: #{parsed["value"]} workspace=#{workspace_id}")
            {:error, {:invalid_lifecycle_stage, parsed["value"]}}

          other ->
            Logger.error("CRM bad request: #{other} workspace=#{workspace_id}")
            {:error, {:bad_request, parsed}}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("CRM authentication failed workspace=#{workspace_id}")
        {:error, :auth_failed}

      {:ok, %HTTPoison.Response{status_code: 403, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["error_code"] do
          "READ_ONLY_CONTACT" ->
            Logger.warning("CRM contact is read-only: crm_id=#{parsed["contact_id"]}")
            {:error, {:read_only_contact, parsed["contact_id"]}}

          "PLAN_LIMIT_REACHED" ->
            Logger.error("CRM contact plan limit reached workspace=#{workspace_id}")
            AlertDispatcher.notify_ops({:crm_plan_limit, workspace_id})
            {:error, :plan_limit_reached}

          _other ->
            Logger.error("CRM forbidden: #{inspect(parsed)}")
            {:error, :forbidden}
        end

      {:ok, %HTTPoison.Response{status_code: 429, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        retry_after = parsed["retry_after"] || 60
        Logger.warning("CRM rate limited, retry_after=#{retry_after}s workspace=#{workspace_id}")
        {:error, {:rate_limited, retry_after}}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("CRM server error: status=#{status} workspace=#{workspace_id}")
        {:error, :crm_unavailable}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("CRM request timed out workspace=#{workspace_id}")
        {:error, :crm_timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("CRM network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @spec delete_contact(String.t(), String.t()) :: :ok | {:error, atom()}
  def delete_contact(workspace_id, crm_id) do
    headers = build_headers(workspace_id)

    case HTTPoison.delete("#{@api_base}/contacts/#{crm_id}", headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 204}} -> :ok
      {:ok, %HTTPoison.Response{status_code: 404}} -> {:error, :not_found}
      {:ok, %HTTPoison.Response{status_code: 403}} -> {:error, :forbidden}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, {:network_error, reason}}
    end
  end

  # Private helpers

  defp build_headers(workspace_id) do
    api_key = Application.fetch_env!(:my_app, :crm_api_key)
    [
      {"Authorization", "Bearer #{api_key}"},
      {"X-Workspace-ID", workspace_id},
      {"Content-Type", "application/json"}
    ]
  end
end
```
