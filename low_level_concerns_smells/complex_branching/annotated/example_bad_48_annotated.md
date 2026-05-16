# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `handle_envelope_response/2` function
- **Affected function(s):** `handle_envelope_response/2`
- **Short explanation:** The function is the sole handler for every possible response from a document e-signature API envelope creation endpoint — created, sent, voided, completed, declined by a signer, document-format errors, recipient-validation errors, and server faults — all in one deeply nested `case` expression. Concentrating all this logic in one function raises cyclomatic complexity and makes individual branches impossible to test in isolation.

---

```elixir
defmodule Legal.ESignatureClient do
  @moduledoc """
  HTTP client for the e-signature platform API (DocuSign / HelloSign style).
  Handles envelope creation, recipient management, status polling,
  document retrieval, and void operations.
  """

  require Logger

  @base_url "https://esign-api.platform.io/v3"

  def create_envelope(document_data, recipients, opts \\ []) do
    subject = Keyword.get(opts, :subject, "Document for signature")
    message = Keyword.get(opts, :message, "Please review and sign this document.")
    expires_in_days = Keyword.get(opts, :expires_in_days, 30)
    auto_remind_days = Keyword.get(opts, :auto_remind_days, [3, 7])
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    payload = %{
      subject: subject,
      message: message,
      expires_in_days: expires_in_days,
      auto_remind_days: auto_remind_days,
      documents:
        Enum.map(document_data, fn doc ->
          %{
            name: doc.name,
            file_base64: doc.base64_content,
            mime_type: doc.mime_type,
            order: doc.order
          }
        end),
      recipients:
        Enum.map(recipients, fn r ->
          %{
            name: r.name,
            email: r.email,
            role: r.role,
            routing_order: r.routing_order,
            authentication: Map.get(r, :authentication, "email")
          }
        end)
    }

    case http_post("#{@base_url}/envelopes", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        handle_envelope_response(raw, %{subject: subject, key: idempotency_key})

      {:error, :timeout} ->
        {:error, :esign_platform_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def envelope_status(envelope_id) do
    case http_get("#{@base_url}/envelopes/#{envelope_id}", auth_headers()) do
      {:ok, %{status: 200, body: %{"status" => s, "envelope_id" => eid, "completed_at" => ts}}} ->
        {:ok, %{envelope_id: eid, status: String.to_atom(s), completed_at: ts}}

      {:ok, %{status: 200, body: %{"status" => s, "envelope_id" => eid}}} ->
        {:ok, %{envelope_id: eid, status: String.to_atom(s), completed_at: nil}}

      {:ok, %{status: 404}} ->
        {:error, :envelope_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def void_envelope(envelope_id, void_reason) do
    payload = %{void_reason: void_reason}

    case http_post("#{@base_url}/envelopes/#{envelope_id}/void", payload, auth_headers()) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :envelope_not_found}
      {:ok, %{status: 409}} -> {:error, :envelope_already_completed}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `handle_envelope_response/2` is the sole
  # handler for every HTTP status and body variant from the envelope creation
  # endpoint. The 200 path branches on created (with embedded signing URL), sent
  # (awaiting signers), voided, and completed body shapes — each with different
  # required fields. The 400 path branches on invalid_document_format,
  # password_protected_document, invalid_recipient_email, duplicate_recipient,
  # too_many_documents, and generic errors. Further arms handle signer-declined
  # (403), signing-expired (410), and two shapes of server errors. Packing all
  # of this into one function makes it very long and fragile: a MatchError in
  # any single arm (e.g., missing "signing_url") crashes the whole function.
  defp handle_envelope_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "created",
            "envelope_id" => eid,
            "signing_url" => url,
            "expires_at" => exp
          } ->
            {:ok,
             %{
               envelope_id: eid,
               status: :created,
               signing_url: url,
               expires_at: exp,
               completed_at: nil,
               void_reason: nil
             }}

          %{"status" => "created", "envelope_id" => eid} ->
            {:ok,
             %{
               envelope_id: eid,
               status: :created,
               signing_url: nil,
               expires_at: nil,
               completed_at: nil,
               void_reason: nil
             }}

          %{
            "status" => "sent",
            "envelope_id" => eid,
            "pending_signers" => signers,
            "expires_at" => exp
          } ->
            Logger.info("Envelope sent eid=#{eid} pending=#{length(signers)} context=#{inspect(context)}")

            {:ok,
             %{
               envelope_id: eid,
               status: :sent,
               pending_signers: signers,
               expires_at: exp,
               completed_at: nil
             }}

          %{
            "status" => "completed",
            "envelope_id" => eid,
            "completed_at" => ts,
            "download_url" => url
          } ->
            {:ok,
             %{
               envelope_id: eid,
               status: :completed,
               completed_at: ts,
               download_url: url,
               void_reason: nil
             }}

          %{
            "status" => "voided",
            "envelope_id" => eid,
            "voided_at" => ts,
            "void_reason" => reason
          } ->
            {:ok,
             %{
               envelope_id: eid,
               status: :voided,
               voided_at: ts,
               void_reason: reason,
               completed_at: nil
             }}

          %{"status" => unknown} ->
            {:error, {:unknown_envelope_status, unknown}}

          _ ->
            {:error, :malformed_envelope_body}
        end

      %{status: 201, body: %{"envelope_id" => eid, "status" => "created"}} ->
        {:ok, %{envelope_id: eid, status: :created}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "invalid_document_format", "document_name" => name, "expected" => formats} ->
            {:error, {:invalid_document_format, name, formats}}

          %{"error" => "password_protected_document", "document_name" => name} ->
            {:error, {:password_protected_document, name}}

          %{"error" => "invalid_recipient_email", "email" => email} ->
            {:error, {:invalid_recipient_email, email}}

          %{"error" => "duplicate_recipient", "email" => email} ->
            {:error, {:duplicate_recipient, email}}

          %{"error" => "too_many_documents", "max" => max} ->
            {:error, {:too_many_documents, max}}

          %{"error" => "missing_signature_field", "document" => doc} ->
            {:error, {:missing_signature_field, doc}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("E-sign platform unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "signer_declined", "reason" => reason}} ->
        {:error, {:signer_declined, reason}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 409, body: %{"error" => "duplicate_envelope", "existing_id" => eid}} ->
        {:error, {:duplicate_envelope, eid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 410, body: %{"error" => "signing_expired", "expired_at" => ts}} ->
        {:error, {:signing_expired, ts}}

      %{status: 410} ->
        {:error, :gone}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"request_id" => rid, "message" => msg}} ->
        Logger.error("E-sign 500 request_id=#{rid} msg=#{msg}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled e-sign status=#{status} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp auth_headers do
    [
      {"Authorization", "Bearer #{System.get_env("ESIGN_API_KEY", "")}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp build_headers(idempotency_key) do
    [{"Idempotency-Key", idempotency_key} | auth_headers()]
  end

  defp http_get(_url, _headers), do: {:error, :not_implemented}
  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
