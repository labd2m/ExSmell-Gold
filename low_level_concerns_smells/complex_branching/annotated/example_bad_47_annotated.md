# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `handle_booking_response/2` function
- **Affected function(s):** `handle_booking_response/2`
- **Short explanation:** The function is the single handler for every outcome of a booking API endpoint — confirmed, waitlisted, pending-payment, slot-taken, capacity-exceeded, blackout-period, and multiple server faults — all within one deeply nested `case` expression. This concentrates all branching responsibility in one place, raises cyclomatic complexity sharply, and makes the function fragile to body schema variations.

---

```elixir
defmodule Scheduling.AppointmentClient do
  @moduledoc """
  HTTP client for the third-party appointment scheduling platform.
  Handles slot discovery, booking creation, rescheduling, cancellation,
  and waitlist management.
  """

  require Logger

  @base_url "https://scheduling-api.platform.io/v2"

  def available_slots(service_id, provider_id, date_range, opts \\ []) do
    duration_minutes = Keyword.get(opts, :duration_minutes, 60)
    timezone = Keyword.get(opts, :timezone, "UTC")

    params = %{
      service_id: service_id,
      provider_id: provider_id,
      from: date_range.from,
      to: date_range.to,
      duration_minutes: duration_minutes,
      timezone: timezone
    }

    case http_get("#{@base_url}/slots", params, auth_headers()) do
      {:ok, %{status: 200, body: %{"slots" => slots}}} ->
        {:ok, Enum.map(slots, &parse_slot/1)}

      {:ok, %{status: 404}} ->
        {:error, :provider_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def book_appointment(slot_id, customer, service_id, opts \\ []) do
    notes = Keyword.get(opts, :notes, "")
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    payment_method_id = Keyword.get(opts, :payment_method_id)
    reminder_minutes = Keyword.get(opts, :reminder_minutes, [60, 1440])

    payload = %{
      slot_id: slot_id,
      service_id: service_id,
      customer: %{
        name: customer.name,
        email: customer.email,
        phone: customer.phone
      },
      notes: notes,
      payment_method_id: payment_method_id,
      reminder_minutes: reminder_minutes
    }

    case http_post("#{@base_url}/appointments", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        handle_booking_response(raw, %{slot_id: slot_id, customer_email: customer.email})

      {:error, :timeout} ->
        {:error, :scheduling_platform_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def cancel_appointment(appointment_id, reason \\ nil) do
    payload = %{cancellation_reason: reason}

    case http_delete("#{@base_url}/appointments/#{appointment_id}", payload, auth_headers()) do
      {:ok, %{status: 200, body: %{"refund_amount_cents" => refund}}} ->
        {:ok, %{canceled: true, refund_amount_cents: refund}}

      {:ok, %{status: 200}} ->
        {:ok, %{canceled: true, refund_amount_cents: 0}}

      {:ok, %{status: 404}} ->
        {:error, :appointment_not_found}

      {:ok, %{status: 409}} ->
        {:error, :cancellation_window_expired}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `handle_booking_response/2` is the sole
  # function handling every possible HTTP status and body variant from a single
  # booking endpoint. The 200 path branches on three distinct body shapes:
  # confirmed (with and without payment details), waitlisted, and
  # pending_payment. The 400 path branches on slot_not_available,
  # slot_already_booked, capacity_exceeded, blackout_period, invalid_service,
  # invalid_customer_data, and generic errors. Further arms cover deposit
  # required (402), double-booking (409), and server faults. Concentrating all
  # of these in one function makes it very long, and a MatchError in any single
  # arm prevents all other response types from being processed.
  defp handle_booking_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "confirmed",
            "appointment_id" => aid,
            "starts_at" => start_ts,
            "ends_at" => end_ts,
            "confirmation_code" => code,
            "payment_amount_cents" => amount
          } ->
            {:ok,
             %{
               appointment_id: aid,
               status: :confirmed,
               starts_at: start_ts,
               ends_at: end_ts,
               confirmation_code: code,
               payment_amount_cents: amount,
               waitlist_position: nil
             }}

          %{
            "status" => "confirmed",
            "appointment_id" => aid,
            "starts_at" => start_ts,
            "ends_at" => end_ts,
            "confirmation_code" => code
          } ->
            {:ok,
             %{
               appointment_id: aid,
               status: :confirmed,
               starts_at: start_ts,
               ends_at: end_ts,
               confirmation_code: code,
               payment_amount_cents: 0,
               waitlist_position: nil
             }}

          %{
            "status" => "waitlisted",
            "waitlist_id" => wid,
            "position" => pos,
            "estimated_wait_days" => wait
          } ->
            Logger.info("Customer waitlisted context=#{inspect(context)} position=#{pos}")

            {:ok,
             %{
               appointment_id: nil,
               status: :waitlisted,
               waitlist_id: wid,
               waitlist_position: pos,
               estimated_wait_days: wait
             }}

          %{"status" => "waitlisted", "waitlist_id" => wid, "position" => pos} ->
            {:ok,
             %{
               appointment_id: nil,
               status: :waitlisted,
               waitlist_id: wid,
               waitlist_position: pos,
               estimated_wait_days: nil
             }}

          %{
            "status" => "pending_payment",
            "appointment_id" => aid,
            "payment_url" => url,
            "expires_at" => exp
          } ->
            {:ok,
             %{
               appointment_id: aid,
               status: :pending_payment,
               payment_url: url,
               payment_expires_at: exp
             }}

          %{"status" => unknown} ->
            {:error, {:unknown_booking_status, unknown}}

          _ ->
            {:error, :malformed_booking_body}
        end

      %{status: 201, body: %{"appointment_id" => aid, "status" => "confirmed"}} ->
        {:ok, %{appointment_id: aid, status: :confirmed}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "slot_not_available", "slot_id" => sid} ->
            {:error, {:slot_not_available, sid}}

          %{"error" => "slot_already_booked", "slot_id" => sid} ->
            {:error, {:slot_already_booked, sid}}

          %{"error" => "capacity_exceeded", "current_capacity" => cap} ->
            {:error, {:capacity_exceeded, cap}}

          %{"error" => "blackout_period", "blackout_until" => ts} ->
            {:error, {:blackout_period, ts}}

          %{"error" => "invalid_service", "service_id" => sid} ->
            {:error, {:invalid_service, sid}}

          %{"error" => "invalid_customer_data", "field" => field} ->
            {:error, {:invalid_customer_data, field}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("Scheduling API unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 402, body: %{"error" => "deposit_required", "deposit_cents" => dep}} ->
        {:error, {:deposit_required, dep}}

      %{status: 402} ->
        {:error, :payment_required}

      %{status: 409, body: %{"error" => "duplicate_booking", "existing_id" => eid}} ->
        {:error, {:duplicate_booking, eid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"request_id" => rid}} ->
        Logger.error("Scheduling platform 500 request_id=#{rid} context=#{inspect(context)}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled scheduling status=#{status} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp parse_slot(%{"slot_id" => id, "starts_at" => s, "ends_at" => e, "available" => a}) do
    %{slot_id: id, starts_at: s, ends_at: e, available: a}
  end

  defp parse_slot(slot), do: slot

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp auth_headers do
    [{"Authorization", "Bearer #{System.get_env("SCHEDULING_API_KEY", "")}"}]
  end

  defp build_headers(idempotency_key) do
    [{"Idempotency-Key", idempotency_key}, {"Content-Type", "application/json"} | auth_headers()]
  end

  defp http_get(_url, _params, _headers), do: {:error, :not_implemented}
  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_delete(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
