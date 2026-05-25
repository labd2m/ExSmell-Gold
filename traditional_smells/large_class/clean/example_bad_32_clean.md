```elixir
defmodule PatientCareManager do
  @moduledoc """
  Manages patient registration, clinical care, and billing operations.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Healthcare.{
    Patient,
    Appointment,
    Prescription,
    LabResult,
    MedicalBill,
    BillLineItem,
    InsuranceClaim
  }
  alias MyApp.Mailer

  @appointment_lead_time_hours 2
  @prescription_max_days 90
  @insurance_claim_window_days 90


  def register_patient(attrs) do
    with {:ok, patient} <-
           %Patient{}
           |> Patient.changeset(attrs)
           |> Repo.insert() do
      send_registration_confirmation(patient)
      Logger.info("Patient #{patient.id} registered: #{patient.mrn}")
      {:ok, patient}
    end
  end

  def update_patient(patient_id, attrs) do
    Repo.get!(Patient, patient_id)
    |> Patient.changeset(attrs)
    |> Repo.update()
  end

  def find_patient_by_mrn(mrn) do
    case Repo.get_by(Patient, mrn: mrn) do
      nil -> {:error, :not_found}
      patient -> {:ok, patient}
    end
  end

  def update_insurance(patient_id, insurance_attrs) do
    Repo.get!(Patient, patient_id)
    |> Patient.changeset(%{insurance: insurance_attrs})
    |> Repo.update()
  end

  defp send_registration_confirmation(%Patient{name: name, email: email}) do
    Mailer.send(%{
      to: email,
      subject: "Welcome to HealthCare Portal",
      body: "Dear #{name}, your patient account has been created. Your MRN is on your profile."
    })
  end


  def book_appointment(patient_id, provider_id, datetime, %{type: type, notes: notes}) do
    with :ok <- validate_future_datetime(datetime),
         :ok <- check_provider_availability(provider_id, datetime) do
      {:ok, appt} =
        Repo.insert(%Appointment{
          patient_id: patient_id,
          provider_id: provider_id,
          scheduled_at: datetime,
          type: type,
          notes: notes,
          status: :scheduled
        })

      schedule_appointment_reminder(appt)
      {:ok, appt}
    end
  end

  defp validate_future_datetime(dt) do
    min_dt = DateTime.add(DateTime.utc_now(), @appointment_lead_time_hours * 3600, :second)
    if DateTime.compare(dt, min_dt) == :gt, do: :ok, else: {:error, :too_soon}
  end

  defp check_provider_availability(provider_id, datetime) do
    conflict =
      Repo.exists?(
        from a in Appointment,
          where:
            a.provider_id == ^provider_id and
              a.scheduled_at == ^datetime and
              a.status in [:scheduled, :confirmed]
      )

    if conflict, do: {:error, :provider_unavailable}, else: :ok
  end

  defp schedule_appointment_reminder(%Appointment{id: id, scheduled_at: dt, patient_id: pid}) do
    remind_at = DateTime.add(dt, -24 * 3600, :second)

    if DateTime.compare(remind_at, DateTime.utc_now()) == :gt do
      %MyApp.Healthcare.AppointmentReminder{
        appointment_id: id,
        patient_id: pid,
        send_at: remind_at,
        status: :pending
      }
      |> Repo.insert()
    end
  end

  def cancel_appointment(appointment_id, reason) do
    Repo.get!(Appointment, appointment_id)
    |> Appointment.changeset(%{status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
  end


  def issue_prescription(patient_id, provider_id, attrs) do
    days = Map.get(attrs, :days_supply, 30)

    if days > @prescription_max_days do
      {:error, :exceeds_max_days}
    else
      expires_at = DateTime.add(DateTime.utc_now(), days * 86400, :second)

      Repo.insert(%Prescription{
        patient_id: patient_id,
        provider_id: provider_id,
        medication: attrs.medication,
        dosage: attrs.dosage,
        frequency: attrs.frequency,
        days_supply: days,
        refills_remaining: Map.get(attrs, :refills, 0),
        issued_at: DateTime.utc_now(),
        expires_at: expires_at,
        status: :active
      })
    end
  end

  def refill_prescription(prescription_id) do
    prescription = Repo.get!(Prescription, prescription_id)

    cond do
      prescription.refills_remaining <= 0 ->
        {:error, :no_refills_remaining}

      DateTime.compare(prescription.expires_at, DateTime.utc_now()) == :lt ->
        {:error, :prescription_expired}

      true ->
        prescription
        |> Prescription.changeset(%{refills_remaining: prescription.refills_remaining - 1})
        |> Repo.update()
    end
  end

  def active_prescriptions(patient_id) do
    now = DateTime.utc_now()

    Repo.all(
      from p in Prescription,
        where: p.patient_id == ^patient_id and p.status == :active and p.expires_at > ^now
    )
  end


  def record_lab_result(patient_id, provider_id, %{test: test, result: result, reference_range: ref, collected_at: ts}) do
    is_abnormal = outside_reference_range?(result, ref)

    {:ok, lab_result} =
      Repo.insert(%LabResult{
        patient_id: patient_id,
        ordered_by: provider_id,
        test_name: test,
        result_value: result,
        reference_range: ref,
        abnormal: is_abnormal,
        collected_at: ts,
        resulted_at: DateTime.utc_now()
      })

    if is_abnormal do
      patient = Repo.get!(Patient, patient_id)
      notify_abnormal_result(patient, lab_result)
    end

    {:ok, lab_result}
  end

  defp outside_reference_range?(%{value: v, unit: _}, %{low: low, high: high}) do
    v < low || v > high
  end

  defp outside_reference_range?(_, _), do: false

  defp notify_abnormal_result(%Patient{email: email}, %LabResult{test_name: test}) do
    Mailer.send(%{
      to: email,
      subject: "Attention: Abnormal Lab Result",
      body: "Your #{test} result requires attention. Please contact your provider."
    })
  end

  def lab_history(patient_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from l in LabResult,
        where: l.patient_id == ^patient_id,
        order_by: [desc: l.resulted_at],
        limit: ^limit
    )
  end


  def generate_bill(patient_id, appointment_id, line_items) do
    subtotal = Enum.reduce(line_items, Decimal.new(0), &Decimal.add(&2, &1.amount))
    copay = calculate_copay(patient_id, subtotal)
    insurance_portion = Decimal.sub(subtotal, copay)

    {:ok, bill} =
      Repo.insert(%MedicalBill{
        patient_id: patient_id,
        appointment_id: appointment_id,
        subtotal: subtotal,
        patient_responsibility: copay,
        insurance_portion: insurance_portion,
        status: :pending,
        issued_at: DateTime.utc_now()
      })

    Enum.each(line_items, fn item ->
      Repo.insert(%BillLineItem{bill_id: bill.id, description: item.description, amount: item.amount})
    end)

    {:ok, bill}
  end

  defp calculate_copay(patient_id, total) do
    patient = Repo.get!(Patient, patient_id)

    case patient.insurance do
      %{copay_percent: pct} -> Decimal.mult(total, Decimal.div(pct, 100))
      _ -> total
    end
  end

  def submit_insurance_claim(%MedicalBill{} = bill) do
    patient = Repo.get!(Patient, bill.patient_id)

    if is_nil(patient.insurance) do
      {:error, :no_insurance_on_file}
    else
      age_days = DateTime.diff(DateTime.utc_now(), bill.issued_at, :day)

      if age_days > @insurance_claim_window_days do
        {:error, :claim_window_expired}
      else
        Repo.insert(%InsuranceClaim{
          bill_id: bill.id,
          patient_id: bill.patient_id,
          payer_id: patient.insurance.payer_id,
          amount_claimed: bill.insurance_portion,
          status: :submitted,
          submitted_at: DateTime.utc_now()
        })
      end
    end
  end
end
```
