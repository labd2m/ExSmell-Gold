```elixir
defmodule Healthcare.Records.AccessAudit do
  @moduledoc """
  Records and queries access audit trails for patient health records.

  Every access to a protected record is logged with actor identity,
  access reason, and timestamp. Audit trails are append-only and
  support structured compliance queries.
  """

  alias Healthcare.Records.{AuditEntry, Patient, Practitioner}
  alias Healthcare.Repo
  import Ecto.Query, warn: false

  @type access_reason ::
          :treatment
          | :administrative
          | :emergency
          | :research_consented
          | :legal_request

  @type audit_params :: %{
          patient_id: Ecto.UUID.t(),
          practitioner_id: Ecto.UUID.t(),
          record_type: atom(),
          access_reason: access_reason(),
          ip_address: String.t()
        }

  @doc """
  Records an access event for a patient record.

  Returns `{:ok, entry}` on success or `{:error, changeset}` on validation failure.
  """
  @spec log_access(audit_params()) :: {:ok, AuditEntry.t()} | {:error, Ecto.Changeset.t()}
  def log_access(%{patient_id: _, practitioner_id: _, access_reason: _} = params) do
    %AuditEntry{}
    |> AuditEntry.changeset(Map.put(params, :accessed_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  @doc """
  Returns the access audit trail for a specific patient within an optional date range.
  """
  @spec patient_trail(Ecto.UUID.t(), Date.t() | nil, Date.t() | nil) :: [AuditEntry.t()]
  def patient_trail(patient_id, from_date \\ nil, to_date \\ nil) do
    AuditEntry
    |> where([a], a.patient_id == ^patient_id)
    |> apply_date_filter(:from, from_date)
    |> apply_date_filter(:to, to_date)
    |> order_by([a], desc: a.accessed_at)
    |> preload(:practitioner)
    |> Repo.all()
  end

  @doc """
  Returns all accesses made by a practitioner, optionally filtered by reason.
  """
  @spec practitioner_accesses(Ecto.UUID.t(), access_reason() | nil) :: [AuditEntry.t()]
  def practitioner_accesses(practitioner_id, reason \\ nil) do
    AuditEntry
    |> where([a], a.practitioner_id == ^practitioner_id)
    |> apply_reason_filter(reason)
    |> order_by([a], desc: a.accessed_at)
    |> preload(:patient)
    |> Repo.all()
  end

  @doc """
  Returns an access frequency summary grouped by record type for compliance reporting.
  """
  @spec access_summary(Ecto.UUID.t(), Date.t(), Date.t()) :: [map()]
  def access_summary(patient_id, from_date, to_date) do
    AuditEntry
    |> where([a], a.patient_id == ^patient_id)
    |> where([a], a.accessed_at >= ^DateTime.new!(from_date, ~T[00:00:00]))
    |> where([a], a.accessed_at <= ^DateTime.new!(to_date, ~T[23:59:59]))
    |> group_by([a], [a.record_type, a.access_reason])
    |> select([a], %{
      record_type: a.record_type,
      access_reason: a.access_reason,
      count: count(a.id)
    })
    |> Repo.all()
  end

  @doc """
  Checks whether a practitioner has accessed a patient record within a given window.
  """
  @spec accessed_recently?(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: boolean()
  def accessed_recently?(patient_id, practitioner_id, within_minutes) do
    cutoff = DateTime.add(DateTime.utc_now(), -within_minutes * 60, :second)

    AuditEntry
    |> where([a], a.patient_id == ^patient_id)
    |> where([a], a.practitioner_id == ^practitioner_id)
    |> where([a], a.accessed_at >= ^cutoff)
    |> Repo.exists?()
  end

  defp apply_date_filter(query, :from, nil), do: query
  defp apply_date_filter(query, :to, nil), do: query

  defp apply_date_filter(query, :from, date) do
    cutoff = DateTime.new!(date, ~T[00:00:00])
    where(query, [a], a.accessed_at >= ^cutoff)
  end

  defp apply_date_filter(query, :to, date) do
    cutoff = DateTime.new!(date, ~T[23:59:59])
    where(query, [a], a.accessed_at <= ^cutoff)
  end

  defp apply_reason_filter(query, nil), do: query
  defp apply_reason_filter(query, reason), do: where(query, [a], a.access_reason == ^reason)
end
```
