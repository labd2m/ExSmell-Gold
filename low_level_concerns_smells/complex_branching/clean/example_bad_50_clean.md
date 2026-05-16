```elixir
defmodule Payroll.DisbursementClient do
  @moduledoc """
  HTTP client for the payroll disbursement platform.
  Handles salary runs, contractor payments, reimbursements, and advances.
  Communicates with the bank transfer gateway and compliance checks.
  """

  require Logger

  @base_url "https://payroll-gateway.fintech.io/api/v2"

  def disburse(run_id, employee_id, amount_cents, account_details, opts \\ []) do
    currency = Keyword.get(opts, :currency, "USD")
    payment_type = Keyword.get(opts, :payment_type, "salary")
    reference = Keyword.get(opts, :reference, "Payroll #{run_id}")
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    scheduled_date = Keyword.get(opts, :scheduled_date)

    payload = %{
      run_id: run_id,
      employee_id: employee_id,
      amount_cents: amount_cents,
      currency: currency,
      payment_type: payment_type,
      reference: reference,
      scheduled_date: scheduled_date,
      bank_account: %{
        routing_number: account_details.routing_number,
        account_number: account_details.account_number,
        account_type: account_details.account_type,
        bank_name: account_details.bank_name,
        country: account_details.country
      }
    }

    headers = build_headers(idempotency_key)

    case http_post("#{@base_url}/disbursements", payload, headers) do
      {:ok, raw} ->
        interpret_disbursement_response(raw, %{run_id: run_id, employee_id: employee_id})

      {:error, :timeout} ->
        {:error, :gateway_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def batch_disburse(run_id, payments) do
    payload = %{
      run_id: run_id,
      payments:
        Enum.map(payments, fn p ->
          %{
            employee_id: p.employee_id,
            amount_cents: p.amount_cents,
            currency: Map.get(p, :currency, "USD"),
            bank_account: p.bank_account
          }
        end)
    }

    case http_post("#{@base_url}/disbursements/batch", payload, build_headers()) do
      {:ok, %{status: 200, body: %{"batch_id" => bid, "accepted" => acc, "rejected" => rej}}} ->
        {:ok, %{batch_id: bid, accepted_count: acc, rejected_count: rej}}

      {:ok, %{status: 400, body: %{"error" => msg}}} ->
        {:error, {:batch_validation_error, msg}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def disbursement_status(disbursement_id) do
    case http_get("#{@base_url}/disbursements/#{disbursement_id}", auth_headers()) do
      {:ok, %{status: 200, body: %{"status" => s, "disbursement_id" => did}}} ->
        {:ok, %{disbursement_id: did, status: String.to_atom(s)}}

      {:ok, %{status: 404}} ->
        {:error, :disbursement_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp interpret_disbursement_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "processed",
            "disbursement_id" => did,
            "bank_reference" => ref,
            "processed_at" => ts,
            "fee_cents" => fee
          } ->
            {:ok,
             %{
               disbursement_id: did,
               status: :processed,
               bank_reference: ref,
               processed_at: ts,
               fee_cents: fee,
               expected_clearance_date: nil
             }}

          %{"status" => "processed", "disbursement_id" => did, "processed_at" => ts} ->
            {:ok,
             %{
               disbursement_id: did,
               status: :processed,
               bank_reference: nil,
               processed_at: ts,
               fee_cents: 0,
               expected_clearance_date: nil
             }}

          %{
            "status" => "pending_clearance",
            "disbursement_id" => did,
            "expected_clearance_date" => date
          } ->
            Logger.info("Disbursement pending clearance context=#{inspect(context)} date=#{date}")

            {:ok,
             %{
               disbursement_id: did,
               status: :pending_clearance,
               bank_reference: nil,
               processed_at: nil,
               fee_cents: 0,
               expected_clearance_date: date
             }}

          %{
            "status" => "scheduled",
            "disbursement_id" => did,
            "scheduled_date" => sched_date
          } ->
            {:ok,
             %{
               disbursement_id: did,
               status: :scheduled,
               scheduled_date: sched_date,
               processed_at: nil,
               fee_cents: 0,
               bank_reference: nil
             }}

          %{"status" => unknown} ->
            {:error, {:unknown_disbursement_status, unknown}}

          _ ->
            {:error, :malformed_disbursement_body}
        end

      %{status: 201, body: %{"disbursement_id" => did, "status" => "queued"}} ->
        {:ok, %{disbursement_id: did, status: :queued}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "invalid_routing_number", "routing_number" => rn} ->
            {:error, {:invalid_routing_number, rn}}

          %{"error" => "invalid_account_number"} ->
            {:error, :invalid_account_number}

          %{"error" => "unsupported_country", "country" => c} ->
            {:error, {:unsupported_country, c}}

          %{"error" => "invalid_amount", "min_cents" => min, "max_cents" => max} ->
            {:error, {:invalid_amount, min, max}}

          %{"error" => "invalid_currency", "supported" => currencies} ->
            {:error, {:invalid_currency, currencies}}

          %{"error" => "missing_employee", "employee_id" => eid} ->
            {:error, {:employee_not_found, eid}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("Payroll gateway unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 402, body: %{"error" => "insufficient_balance", "available_cents" => avail}} ->
        Logger.warning("Insufficient payroll balance available=#{avail} context=#{inspect(context)}")
        {:error, {:insufficient_balance, avail}}

      %{status: 402} ->
        {:error, :insufficient_balance}

      %{status: 403, body: %{"error" => "aml_hold", "hold_id" => hid, "reason" => reason}} ->
        Logger.warning("AML hold placed hold_id=#{hid} context=#{inspect(context)}")
        {:error, {:aml_hold, hid, reason}}

      %{status: 403, body: %{"error" => "compliance_block", "regulation" => reg}} ->
        {:error, {:compliance_block, reg}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 409, body: %{"error" => "duplicate_disbursement", "existing_id" => eid}} ->
        {:error, {:duplicate_disbursement, eid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 451, body: %{"error" => "sanctioned_entity", "list" => list}} ->
        Logger.error("Sanctioned entity detected context=#{inspect(context)} list=#{list}")
        {:error, {:sanctioned_entity, list}}

      %{status: 451} ->
        {:error, :regulatory_block}

      %{status: 500, body: %{"request_id" => rid, "detail" => detail}} ->
        Logger.error("Payroll gateway 500 request_id=#{rid} detail=#{detail}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503, body: %{"maintenance_until" => ts}} ->
        {:error, {:maintenance, ts}}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled payroll gateway status=#{status} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp auth_headers do
    [{"Authorization", "Bearer #{System.get_env("PAYROLL_GATEWAY_KEY", "")}"}]
  end

  defp build_headers(idempotency_key \\ nil) do
    base = [{"Content-Type", "application/json"} | auth_headers()]

    if idempotency_key,
      do: [{"Idempotency-Key", idempotency_key} | base],
      else: base
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_get(_url, _headers), do: {:error, :not_implemented}
end
```
