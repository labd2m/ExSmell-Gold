# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `AppointmentCoordinator` module |
| **Affected functions** | `schedule_appointment/2`, `reschedule_appointment/2`, `cancel_appointment/2` (scheduling reason) and `send_confirmation/1`, `send_reminder/1`, `send_cancellation_notice/1` (notification reason) and `charge_deposit/1`, `refund_deposit/1`, `calculate_late_fee/1` (billing reason) |
| **Explanation** | The module manages appointment scheduling, customer notifications, and billing deposits/fees — three independent concerns. A change to the scheduling algorithm, to the reminder timing or channel, or to the deposit/refund policy would each independently force changes to this single module. |

```elixir
defmodule Clinic.AppointmentCoordinator do
  @moduledoc """
  Handles appointment scheduling, client notifications, and associated billing.
  """

  alias Clinic.Repo
  alias Clinic.Appointments.Appointment
  alias Clinic.Providers.Provider
  alias Clinic.Billing.DepositCharge
  alias Clinic.Notifications.SmsSender
  alias Clinic.Notifications.EmailSender

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has three unrelated reasons
  # to change: (1) appointment slot management and scheduling logic, (2) the
  # timing, content, and channels used for client notifications, and (3) deposit
  # and late-fee billing rules. Each concern evolves independently.

  ## ── Scheduling ───────────────────────────────────────────────────────────────

  @doc "Schedules a new appointment for a client with a given provider."
  @spec schedule_appointment(String.t(), map()) ::
          {:ok, Appointment.t()} | {:error, term()}
  def schedule_appointment(client_id, %{provider_id: pid, starts_at: start, duration_min: dur}) do
    ends_at = DateTime.add(start, dur * 60, :second)

    case check_provider_availability(pid, start, ends_at) do
      :available ->
        attrs = %{
          client_id: client_id,
          provider_id: pid,
          starts_at: start,
          ends_at: ends_at,
          duration_minutes: dur,
          status: :scheduled
        }

        with {:ok, appt} <- Repo.insert(Appointment.changeset(%Appointment{}, attrs)) do
          send_confirmation(appt)
          {:ok, appt}
        end

      {:error, :unavailable} ->
        {:error, :provider_unavailable}
    end
  end

  @doc "Reschedules an existing appointment to a new time slot."
  @spec reschedule_appointment(Appointment.t(), map()) ::
          {:ok, Appointment.t()} | {:error, term()}
  def reschedule_appointment(%Appointment{status: :scheduled} = appt, %{
        starts_at: new_start,
        duration_min: dur
      }) do
    new_ends_at = DateTime.add(new_start, dur * 60, :second)

    case check_provider_availability(appt.provider_id, new_start, new_ends_at) do
      :available ->
        {:ok, updated} =
          appt
          |> Appointment.changeset(%{starts_at: new_start, ends_at: new_ends_at, rescheduled_at: DateTime.utc_now()})
          |> Repo.update()

        send_confirmation(updated)
        {:ok, updated}

      _ ->
        {:error, :provider_unavailable}
    end
  end

  def reschedule_appointment(%Appointment{}, _), do: {:error, :cannot_reschedule}

  @doc "Cancels an appointment and applies a late-fee if within the cancellation window."
  @spec cancel_appointment(Appointment.t(), String.t()) ::
          {:ok, Appointment.t()} | {:error, term()}
  def cancel_appointment(%Appointment{status: :scheduled} = appt, reason) do
    Repo.transaction(fn ->
      {:ok, updated} =
        appt
        |> Appointment.changeset(%{status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()})
        |> Repo.update()

      if within_late_cancellation_window?(appt) do
        {:ok, _fee} = calculate_late_fee(appt)
      end

      send_cancellation_notice(updated)
      updated
    end)
  end

  def cancel_appointment(%Appointment{}, _), do: {:error, :not_scheduled}

  ## ── Notifications ────────────────────────────────────────────────────────────

  @doc "Sends a booking confirmation by email and SMS."
  @spec send_confirmation(Appointment.t()) :: :ok
  def send_confirmation(%Appointment{client_id: cid} = appt) do
    client = Repo.get!(Clinic.Clients.Client, cid)

    EmailSender.deliver(%{
      to: client.email,
      subject: "Appointment Confirmed",
      template: "appt_confirmation",
      assigns: %{starts_at: appt.starts_at, duration: appt.duration_minutes}
    })

    SmsSender.send_text(client.phone, confirmation_sms_text(appt))
    :ok
  end

  @doc "Sends a reminder 24 hours before the appointment."
  @spec send_reminder(Appointment.t()) :: :ok
  def send_reminder(%Appointment{client_id: cid} = appt) do
    client = Repo.get!(Clinic.Clients.Client, cid)

    EmailSender.deliver(%{
      to: client.email,
      subject: "Appointment Reminder — Tomorrow",
      template: "appt_reminder",
      assigns: %{starts_at: appt.starts_at}
    })

    SmsSender.send_text(client.phone, "Reminder: your appointment is tomorrow at #{format_time(appt.starts_at)}.")
    :ok
  end

  @doc "Notifies the client that their appointment has been cancelled."
  @spec send_cancellation_notice(Appointment.t()) :: :ok
  def send_cancellation_notice(%Appointment{client_id: cid} = appt) do
    client = Repo.get!(Clinic.Clients.Client, cid)

    EmailSender.deliver(%{
      to: client.email,
      subject: "Appointment Cancelled",
      template: "appt_cancelled",
      assigns: %{starts_at: appt.starts_at, reason: appt.cancellation_reason}
    })

    :ok
  end

  ## ── Billing ──────────────────────────────────────────────────────────────────

  @doc "Charges a refundable deposit when the appointment is booked."
  @spec charge_deposit(Appointment.t()) :: {:ok, DepositCharge.t()} | {:error, term()}
  def charge_deposit(%Appointment{client_id: cid, id: appt_id}) do
    deposit_cents = Application.get_env(:clinic, :deposit_amount_cents, 2000)

    case Clinic.Billing.Gateway.charge(cid, deposit_cents, description: "Appointment deposit") do
      {:ok, charge} ->
        attrs = %{
          appointment_id: appt_id,
          client_id: cid,
          amount_cents: deposit_cents,
          charge_id: charge.id,
          status: :held
        }

        %DepositCharge{} |> DepositCharge.changeset(attrs) |> Repo.insert()

      {:error, _} = err ->
        err
    end
  end

  @doc "Refunds the deposit after a timely cancellation or completed appointment."
  @spec refund_deposit(Appointment.t()) :: :ok | {:error, term()}
  def refund_deposit(%Appointment{id: appt_id}) do
    case Repo.get_by(DepositCharge, appointment_id: appt_id, status: :held) do
      nil ->
        {:error, :no_deposit}

      deposit ->
        Clinic.Billing.Gateway.refund(deposit.charge_id)
        deposit |> DepositCharge.changeset(%{status: :refunded}) |> Repo.update()
        :ok
    end
  end

  @doc "Calculates a late-cancellation fee (50% of service cost) for same-day cancellations."
  @spec calculate_late_fee(Appointment.t()) :: {:ok, map()} | {:error, term()}
  def calculate_late_fee(%Appointment{client_id: cid, provider_id: pid}) do
    provider = Repo.get!(Provider, pid)
    fee_cents = round(provider.service_rate_cents * 0.5)

    Clinic.Billing.Gateway.charge(cid, fee_cents, description: "Late cancellation fee")
  end

  ## ── Private Helpers ──────────────────────────────────────────────────────────

  defp check_provider_availability(provider_id, starts_at, ends_at) do
    conflict =
      Appointment
      |> where(
        [a],
        a.provider_id == ^provider_id and a.status == :scheduled and
          a.starts_at < ^ends_at and a.ends_at > ^starts_at
      )
      |> Repo.exists?()

    if conflict, do: {:error, :unavailable}, else: :available
  end

  defp within_late_cancellation_window?(%Appointment{starts_at: starts_at}) do
    hours_until = DateTime.diff(starts_at, DateTime.utc_now(), :hour)
    hours_until < 24
  end

  defp confirmation_sms_text(%Appointment{starts_at: t, duration_minutes: d}),
    do: "Your appointment is confirmed for #{format_time(t)} (#{d} min)."

  defp format_time(dt), do: Calendar.strftime(dt, "%b %d at %I:%M %p")

  # VALIDATION: SMELL END
end
```
