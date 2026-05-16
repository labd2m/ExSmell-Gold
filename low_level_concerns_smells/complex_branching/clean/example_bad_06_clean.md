```elixir
defmodule MyApp.Documents.ESignatureClient do
  @moduledoc """
  Client for the DocuSign-compatible e-signature API.
  Manages envelope creation, signer routing, and completion callbacks.
  """

  require Logger

  alias MyApp.Documents.{EnvelopeRecord, SignerWorkflow, TemplateRegistry, StorageMonitor}
  alias MyApp.Notifications.AlertDispatcher

  @api_base "https://api.esignature.io/v3"
  @http_timeout_ms 10_000

  @spec request_signature(String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, atom() | map()}
  def request_signature(template_id, signers, opts \\ []) do
    subject = Keyword.get(opts, :subject, "Please sign this document")
    message = Keyword.get(opts, :message, "")
    expiry_days = Keyword.get(opts, :expiry_days, 30)
    send_now = Keyword.get(opts, :send_now, true)

    headers = build_headers()

    payload = %{
      template_id: template_id,
      signers: signers,
      email_subject: subject,
      email_message: message,
      expiry_days: expiry_days,
      status: if(send_now, do: "sent", else: "created")
    }

    body = Jason.encode!(payload)
    Logger.info("Requesting e-signature: template=#{template_id} signers=#{length(signers)}")

    case HTTPoison.post("#{@api_base}/envelopes", body, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        envelope_id = parsed["envelope_id"]
        EnvelopeRecord.create(%{
          envelope_id: envelope_id,
          template_id: template_id,
          signers: signers,
          status: parsed["status"],
          expiry_days: expiry_days
        })
        Logger.info("Envelope created: #{envelope_id} template=#{template_id}")
        {:ok, %{envelope_id: envelope_id, status: parsed["status"], signing_url: parsed["signing_url"]}}

      {:ok, %HTTPoison.Response{status_code: 202, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.info("Envelope pending signer validation: #{parsed["envelope_id"]}")
        {:ok, %{envelope_id: parsed["envelope_id"], status: :pending_validation}}

      {:ok, %HTTPoison.Response{status_code: 400, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["error_code"] do
          "TEMPLATE_NOT_FOUND" ->
            Logger.error("E-signature template not found: #{template_id}")
            TemplateRegistry.invalidate(template_id)
            {:error, :template_not_found}

          "UNSUPPORTED_FILE_TYPE" ->
            Logger.error("E-signature unsupported file type for template: #{template_id}")
            {:error, :unsupported_file_type}

          "RECIPIENT_COUNT_EXCEEDED" ->
            max = parsed["max_recipients"]
            Logger.warning("E-signature too many signers: #{length(signers)} max=#{max}")
            {:error, {:too_many_recipients, max}}

          "INVALID_SIGNER_EMAIL" ->
            bad_email = parsed["invalid_email"]
            Logger.warning("E-signature invalid signer email: #{bad_email}")
            {:error, {:invalid_signer_email, bad_email}}

          "MISSING_REQUIRED_FIELD" ->
            field = parsed["field_name"]
            Logger.warning("E-signature missing required field: #{field}")
            {:error, {:missing_field, field}}

          other ->
            Logger.error("E-signature bad request: #{other}")
            {:error, {:bad_request, parsed}}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("E-signature API authentication failed")
        {:error, :auth_failed}

      {:ok, %HTTPoison.Response{status_code: 403, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["error_code"] do
          "ENVELOPE_LOCKED" ->
            Logger.warning("E-signature envelope is locked: #{parsed["envelope_id"]}")
            {:error, :envelope_locked}

          "ACCOUNT_SUSPENDED" ->
            Logger.error("E-signature account is suspended")
            AlertDispatcher.notify_ops(:esignature_account_suspended)
            {:error, :account_suspended}

          _other ->
            Logger.error("E-signature forbidden: #{inspect(parsed)}")
            {:error, :forbidden}
        end

      {:ok, %HTTPoison.Response{status_code: 409, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        existing_id = parsed["existing_envelope_id"]
        Logger.info("E-signature duplicate envelope detected, existing=#{existing_id}")
        {:error, {:duplicate_envelope, existing_id}}

      {:ok, %HTTPoison.Response{status_code: 413, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.warning("E-signature storage quota exceeded: used=#{parsed["used_bytes"]}")
        StorageMonitor.alert_quota_exceeded(parsed["used_bytes"], parsed["quota_bytes"])
        {:error, :storage_quota_exceeded}

      {:ok, %HTTPoison.Response{status_code: 429, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        retry_after = parsed["retry_after_seconds"] || 60
        Logger.warning("E-signature API rate limited, retry_after=#{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("E-signature API server error: status=#{status}")
        AlertDispatcher.notify_ops(:esignature_service_down)
        {:error, :service_unavailable}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("E-signature API timeout for template=#{template_id}")
        {:error, :api_timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("E-signature network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @spec get_envelope(String.t()) :: {:ok, map()} | {:error, atom()}
  def get_envelope(envelope_id) do
    headers = build_headers()

    case HTTPoison.get("#{@api_base}/envelopes/#{envelope_id}", headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, Jason.decode!(body)}
      {:ok, %HTTPoison.Response{status_code: 404}} -> {:error, :not_found}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, {:network_error, reason}}
    end
  end

  @spec void_envelope(String.t(), String.t()) :: :ok | {:error, atom()}
  def void_envelope(envelope_id, reason) do
    headers = build_headers()
    body = Jason.encode!(%{void_reason: reason})

    case HTTPoison.put("#{@api_base}/envelopes/#{envelope_id}/void", body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200}} -> :ok
      {:ok, %HTTPoison.Response{status_code: 400}} -> {:error, :cannot_void}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, {:network_error, reason}}
    end
  end

  # Private helpers

  defp build_headers do
    api_key = Application.fetch_env!(:my_app, :esignature_api_key)
    account_id = Application.fetch_env!(:my_app, :esignature_account_id)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"X-Account-ID", account_id},
      {"Content-Type", "application/json"}
    ]
  end
end
```
