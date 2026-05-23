```elixir
defmodule Telemedicine.Consultations do
  @moduledoc """
  Manages telemedicine consultation booking, physician availability checks,
  session link generation, and insurance pre-authorisation.
  """

  require Logger

  alias Telemedicine.Repo
  alias Telemedicine.Schemas.Consultation
  alias Telemedicine.Schemas.BillingRecord
  alias Telemedicine.AvailabilityService
  alias Telemedicine.SessionLinkGenerator
  alias Telemedicine.InsuranceGateway
  alias Telemedicine.Mailer

  @valid_modalities ~w(video audio chat)
  @min_duration_minutes 15
  @max_duration_minutes 120

  def book_consultation(
        patient_id,
        patient_name,
        patient_email,
        patient_phone,
        physician_id,
        specialty,
        scheduled_at,
        duration_minutes,
        modality,
        insurance_provider,
        insurance_member_id
      ) do
    with :ok <- validate_contact(patient_email, patient_phone),
         :ok <- validate_modality(modality),
         :ok <- validate_duration(duration_minutes),
         :ok <- validate_scheduled_at(scheduled_at) do
      slot_end = DateTime.add(scheduled_at, duration_minutes * 60, :second)

      case AvailabilityService.check_physician(physician_id, scheduled_at, slot_end) do
        :unavailable ->
          Logger.warn("Physician #{physician_id} unavailable at #{scheduled_at}")
          {:error, :physician_unavailable}

        :available ->
          pre_auth_ref =
            if insurance_provider && insurance_member_id do
              case InsuranceGateway.pre_authorise(insurance_provider, insurance_member_id, specialty) do
                {:ok, ref} -> ref
                {:error, _} -> nil
              end
            end

          session_link = SessionLinkGenerator.generate(physician_id, patient_id, scheduled_at)

          consultation_attrs = %{
            patient_id: patient_id,
            patient_name: patient_name,
            patient_email: patient_email,
            patient_phone: patient_phone,
            physician_id: physician_id,
            specialty: specialty,
            scheduled_at: scheduled_at,
            ends_at: slot_end,
            duration_minutes: duration_minutes,
            modality: modality,
            session_link: session_link,
            insurance_provider: insurance_provider,
            insurance_member_id: insurance_member_id,
            insurance_pre_auth_ref: pre_auth_ref,
            status: :confirmed,
            inserted_at: DateTime.utc_now()
          }

          case Repo.insert(Consultation.changeset(%Consultation{}, consultation_attrs)) do
            {:ok, consultation} ->
              if insurance_provider do
                Repo.insert!(BillingRecord.changeset(%BillingRecord{}, %{
                  consultation_id: consultation.id,
                  provider: insurance_provider,
                  member_id: insurance_member_id,
                  pre_auth_ref: pre_auth_ref,
                  status: :pending
                }))
              end

              Mailer.send_consultation_confirmation(patient_email, patient_name, consultation)
              Logger.info("Consultation #{consultation.id} booked for patient #{patient_id}")
              {:ok, consultation}

            {:error, changeset} ->
              Logger.error("Consultation booking failed: #{inspect(changeset.errors)}")
              {:error, :booking_failed}
          end
      end
    end
  end

  defp validate_contact(email, phone) do
    cond do
      not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") ->
        {:error, :invalid_email}

      not is_nil(phone) and not Regex.match?(~r/^\+?[1-9]\d{6,14}$/, phone) ->
        {:error, :invalid_phone}

      true ->
        :ok
    end
  end

  defp validate_modality(m) when m in @valid_modalities, do: :ok
  defp validate_modality(m), do: {:error, {:unknown_modality, m}}

  defp validate_duration(d)
       when is_integer(d) and d >= @min_duration_minutes and d <= @max_duration_minutes,
       do: :ok

  defp validate_duration(_), do: {:error, :invalid_duration}

  defp validate_scheduled_at(%DateTime{} = dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :scheduled_at_in_past}
    end
  end

  defp validate_scheduled_at(_), do: {:error, :invalid_scheduled_at}
end
```
