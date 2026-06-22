```elixir
defmodule Healthcare.Records.PatientContext do
  @moduledoc """
  Manages patient records within the healthcare domain. Encapsulates
  all query and mutation logic, ensuring callers interact with patients
  only through this bounded context's public API.
  """

  import Ecto.Query, warn: false

  alias Healthcare.Repo
  alias Healthcare.Records.{Patient, MedicalNote, PatientFilter}

  @type create_attrs :: %{
          required(:first_name) => String.t(),
          required(:last_name) => String.t(),
          required(:date_of_birth) => Date.t(),
          required(:nhs_number) => String.t(),
          optional(:email) => String.t()
        }

  @doc "Returns a filtered list of patients."
  @spec list(PatientFilter.t()) :: [Patient.t()]
  def list(%PatientFilter{} = filter) do
    Patient
    |> apply_name_filter(filter.name_query)
    |> apply_dob_range(filter.dob_from, filter.dob_to)
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> limit(^filter.limit)
    |> Repo.all()
  end

  @doc "Fetches a patient by ID. Returns `{:error, :not_found}` when absent."
  @spec get(pos_integer()) :: {:ok, Patient.t()} | {:error, :not_found}
  def get(id) when is_integer(id) do
    case Repo.get(Patient, id) do
      nil -> {:error, :not_found}
      patient -> {:ok, patient}
    end
  end

  @doc "Fetches a patient by NHS number."
  @spec get_by_nhs_number(String.t()) :: {:ok, Patient.t()} | {:error, :not_found}
  def get_by_nhs_number(nhs_number) when is_binary(nhs_number) do
    case Repo.get_by(Patient, nhs_number: nhs_number) do
      nil -> {:error, :not_found}
      patient -> {:ok, patient}
    end
  end

  @doc "Creates a new patient record."
  @spec create(create_attrs()) :: {:ok, Patient.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Patient{}
    |> Patient.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Adds a medical note to a patient's record."
  @spec add_note(Patient.t(), map()) ::
          {:ok, MedicalNote.t()} | {:error, Ecto.Changeset.t()}
  def add_note(%Patient{id: patient_id}, attrs) when is_map(attrs) do
    attrs_with_patient = Map.put(attrs, :patient_id, patient_id)

    %MedicalNote{}
    |> MedicalNote.changeset(attrs_with_patient)
    |> Repo.insert()
  end

  @doc "Returns all medical notes for a patient, ordered newest first."
  @spec list_notes(Patient.t()) :: [MedicalNote.t()]
  def list_notes(%Patient{id: patient_id}) do
    MedicalNote
    |> where([n], n.patient_id == ^patient_id)
    |> order_by([n], desc: n.inserted_at)
    |> Repo.all()
  end

  @doc "Soft-deletes a patient by setting `archived_at`."
  @spec archive(Patient.t()) :: {:ok, Patient.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Patient{archived_at: nil} = patient) do
    patient
    |> Patient.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def archive(%Patient{} = patient), do: {:ok, patient}

  # ---------------------------------------------------------------------------
  # Private query helpers
  # ---------------------------------------------------------------------------

  @spec apply_name_filter(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  defp apply_name_filter(query, nil), do: query
  defp apply_name_filter(query, ""), do: query

  defp apply_name_filter(query, name) when is_binary(name) do
    pattern = "%#{name}%"
    where(query, [p], ilike(p.last_name, ^pattern) or ilike(p.first_name, ^pattern))
  end

  @spec apply_dob_range(Ecto.Query.t(), Date.t() | nil, Date.t() | nil) :: Ecto.Query.t()
  defp apply_dob_range(query, nil, nil), do: query

  defp apply_dob_range(query, from, nil) when not is_nil(from) do
    where(query, [p], p.date_of_birth >= ^from)
  end

  defp apply_dob_range(query, nil, to) when not is_nil(to) do
    where(query, [p], p.date_of_birth <= ^to)
  end

  defp apply_dob_range(query, from, to) do
    where(query, [p], p.date_of_birth >= ^from and p.date_of_birth <= ^to)
  end
end
```
