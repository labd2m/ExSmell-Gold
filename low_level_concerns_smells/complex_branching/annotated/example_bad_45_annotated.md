# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `handle_verification_response/2` function
- **Affected function(s):** `handle_verification_response/2`
- **Short explanation:** The function is the sole interpreter for every possible response from a single KYC (Know Your Customer) identity-verification API endpoint. It handles approved, pending-review, manual-review, rejected (with multiple rejection sub-reasons), and document-specific failure modes — all in one deeply nested `case` expression. This makes the function long, hard to test per branch, and fragile.

---

```elixir
defmodule Compliance.KycVerificationClient do
  @moduledoc """
  HTTP client for the third-party KYC/AML identity verification provider.
  Handles identity check submissions, status polling, document uploads,
  and adverse media screening.
  """

  require Logger

  @base_url "https://kyc-provider.compliance.io/api/v3"

  def submit_verification(user_id, identity_data, document_data, opts \\ []) do
    level = Keyword.get(opts, :level, "standard")
    callback_url = Keyword.get(opts, :callback_url)

    payload = %{
      external_ref: user_id,
      level: level,
      identity: %{
        first_name: identity_data.first_name,
        last_name: identity_data.last_name,
        date_of_birth: identity_data.dob,
        nationality: identity_data.nationality,
        address: identity_data.address
      },
      document: %{
        type: document_data.type,
        number: document_data.number,
        expiry: document_data.expiry,
        country: document_data.country,
        images: document_data.images
      },
      callback_url: callback_url
    }

    case http_post("#{@base_url}/verifications", payload, auth_headers()) do
      {:ok, raw} ->
        handle_verification_response(raw, user_id)

      {:error, :timeout} ->
        {:error, :provider_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def check_status(verification_id) do
    case http_get("#{@base_url}/verifications/#{verification_id}", auth_headers()) do
      {:ok, %{status: 200, body: %{"status" => status, "verification_id" => vid}}} ->
        {:ok, %{verification_id: vid, status: String.to_atom(status)}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def screen_adverse_media(user_id, full_name, dob) do
    payload = %{external_ref: user_id, name: full_name, date_of_birth: dob}

    case http_post("#{@base_url}/adverse-media", payload, auth_headers()) do
      {:ok, %{status: 200, body: %{"hits" => hits, "risk_score" => score}}} ->
        {:ok, %{hits: hits, risk_score: score}}

      {:ok, %{status: 200, body: %{"hits" => hits}}} ->
        {:ok, %{hits: hits, risk_score: nil}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `handle_verification_response/2` handles
  # every possible HTTP status and body variant from the KYC submission endpoint
  # in a single function. The 200/201 success paths branch on approved (with risk
  # score), pending_review, and manual_review shapes. The 400 path fans out across
  # document_expired, document_unreadable, face_mismatch, unsupported_document,
  # invalid_country, underage, and generic validation errors. Further arms handle
  # watchlist hits (403), duplicate submissions (409), and server faults. All
  # these branches share the same function body, making cyclomatic complexity very
  # high. A MatchError in any one arm (e.g., missing "risk_score") stops all
  # response types from being handled.
  defp handle_verification_response(response, user_id) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "approved",
            "verification_id" => vid,
            "risk_score" => score,
            "approved_at" => ts,
            "level" => level
          } ->
            {:ok,
             %{
               verification_id: vid,
               status: :approved,
               risk_score: score,
               approved_at: ts,
               level: level,
               rejection_reasons: []
             }}

          %{"status" => "approved", "verification_id" => vid, "approved_at" => ts} ->
            {:ok,
             %{
               verification_id: vid,
               status: :approved,
               risk_score: nil,
               approved_at: ts,
               level: "standard",
               rejection_reasons: []
             }}

          %{
            "status" => "pending_review",
            "verification_id" => vid,
            "estimated_review_time_hours" => eta
          } ->
            Logger.info("KYC pending review user=#{user_id} vid=#{vid} eta=#{eta}h")

            {:ok,
             %{
               verification_id: vid,
               status: :pending_review,
               estimated_review_hours: eta,
               risk_score: nil,
               rejection_reasons: []
             }}

          %{"status" => "pending_review", "verification_id" => vid} ->
            {:ok,
             %{
               verification_id: vid,
               status: :pending_review,
               estimated_review_hours: nil,
               risk_score: nil,
               rejection_reasons: []
             }}

          %{
            "status" => "manual_review",
            "verification_id" => vid,
            "assigned_to" => analyst
          } ->
            {:ok,
             %{
               verification_id: vid,
               status: :manual_review,
               analyst: analyst,
               risk_score: nil,
               rejection_reasons: []
             }}

          %{"status" => "rejected", "verification_id" => vid, "reasons" => reasons} ->
            Logger.warning("KYC rejected user=#{user_id} vid=#{vid} reasons=#{inspect(reasons)}")
            {:error, {:kyc_rejected, vid, reasons}}

          %{"status" => unknown} ->
            {:error, {:unknown_kyc_status, unknown}}

          _ ->
            {:error, :malformed_kyc_body}
        end

      %{status: 201, body: %{"verification_id" => vid, "status" => "submitted"}} ->
        {:ok,
         %{
           verification_id: vid,
           status: :submitted,
           risk_score: nil,
           rejection_reasons: []
         }}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "document_expired", "expired_at" => ts} ->
            {:error, {:document_expired, ts}}

          %{"error" => "document_unreadable", "side" => side} ->
            {:error, {:document_unreadable, side}}

          %{"error" => "face_mismatch", "confidence" => conf} ->
            {:error, {:face_mismatch, conf}}

          %{"error" => "unsupported_document_type", "supported" => types} ->
            {:error, {:unsupported_document_type, types}}

          %{"error" => "invalid_country", "country" => country} ->
            {:error, {:invalid_country, country}}

          %{"error" => "underage", "minimum_age" => age} ->
            {:error, {:underage, age}}

          %{"error" => "missing_field", "field" => field} ->
            {:error, {:missing_field, field}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("KYC provider unauthorized for user=#{user_id}")
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "watchlist_hit", "hit_details" => details}} ->
        Logger.warning("KYC watchlist hit user=#{user_id} details=#{inspect(details)}")
        {:error, {:watchlist_hit, details}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 409, body: %{"error" => "duplicate_submission", "existing_id" => eid}} ->
        {:error, {:duplicate_submission, eid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"incident_id" => iid}} ->
        Logger.error("KYC provider 500 incident_id=#{iid} user=#{user_id}")
        {:error, {:server_error, iid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled KYC status=#{status} user=#{user_id} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp auth_headers do
    key = System.get_env("KYC_PROVIDER_API_KEY", "")
    [{"Authorization", "Bearer #{key}"}, {"Content-Type", "application/json"}]
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_get(_url, _headers), do: {:error, :not_implemented}
end
```
