**File:** `example_good_1315.md`

```elixir
defmodule Consent.Purpose do
  @moduledoc "Defines a named data processing purpose for consent tracking."

  @enforce_keys [:id, :name, :description, :version]
  defstruct [:id, :name, :description, :version, :lawful_basis]

  @type lawful_basis :: :consent | :legitimate_interest | :contract | :legal_obligation
  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          description: String.t(),
          version: String.t(),
          lawful_basis: lawful_basis()
        }
end

defmodule Consent.Record do
  @moduledoc "Schema representing a user's consent decision for a specific purpose."

  use Ecto.Schema
  import Ecto.Changeset

  @type decision :: :granted | :denied | :withdrawn
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: String.t(),
          purpose_id: String.t(),
          purpose_version: String.t(),
          decision: decision(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          recorded_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "consent_records" do
    field :user_id, :string
    field :purpose_id, :string
    field :purpose_version, :string
    field :decision, Ecto.Enum, values: [:granted, :denied, :withdrawn]
    field :ip_address, :string
    field :user_agent, :string
    field :recorded_at, :utc_datetime_usec
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:user_id, :purpose_id, :purpose_version, :decision, :ip_address, :user_agent, :recorded_at])
    |> validate_required([:user_id, :purpose_id, :purpose_version, :decision, :recorded_at])
    |> validate_length(:user_id, min: 1)
    |> validate_length(:purpose_id, min: 1)
  end
end

defmodule Consent.Manager do
  @moduledoc """
  Records and queries user consent decisions. Every mutation creates
  a new immutable consent record, preserving a full audit trail.
  """

  import Ecto.Query, warn: false

  alias Consent.{Purpose, Record}
  alias MyApp.Repo

  @type record_opts :: [ip_address: String.t(), user_agent: String.t()]

  @spec grant(String.t(), Purpose.t(), record_opts()) ::
          {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def grant(user_id, %Purpose{} = purpose, opts \\ []) do
    record_decision(user_id, purpose, :granted, opts)
  end

  @spec deny(String.t(), Purpose.t(), record_opts()) ::
          {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def deny(user_id, %Purpose{} = purpose, opts \\ []) do
    record_decision(user_id, purpose, :denied, opts)
  end

  @spec withdraw(String.t(), Purpose.t(), record_opts()) ::
          {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def withdraw(user_id, %Purpose{} = purpose, opts \\ []) do
    record_decision(user_id, purpose, :withdrawn, opts)
  end

  @spec current_decision(String.t(), Purpose.t()) :: {:ok, Record.decision()} | {:error, :no_record}
  def current_decision(user_id, %Purpose{id: purpose_id}) do
    result =
      Record
      |> where([r], r.user_id == ^user_id and r.purpose_id == ^to_string(purpose_id))
      |> order_by([r], desc: r.recorded_at)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :no_record}
      record -> {:ok, record.decision}
    end
  end

  @spec has_granted?(String.t(), Purpose.t()) :: boolean()
  def has_granted?(user_id, %Purpose{} = purpose) do
    case current_decision(user_id, purpose) do
      {:ok, :granted} -> true
      _ -> false
    end
  end

  @spec history(String.t(), keyword()) :: [Record.t()]
  def history(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Record
    |> where([r], r.user_id == ^user_id)
    |> order_by([r], desc: r.recorded_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp record_decision(user_id, %Purpose{id: pid, version: ver}, decision, opts) do
    attrs = %{
      user_id: user_id,
      purpose_id: to_string(pid),
      purpose_version: ver,
      decision: decision,
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent),
      recorded_at: DateTime.utc_now()
    }

    %Record{}
    |> Record.changeset(attrs)
    |> Repo.insert()
  end
end
```
