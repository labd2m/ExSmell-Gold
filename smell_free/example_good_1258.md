```elixir
defmodule Consent.Record do
  @moduledoc """
  An immutable audit record capturing a user's consent decision for a
  specific policy version. Records are append-only — revocation creates
  a new record with status `:withdrawn` rather than mutating existing rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type status :: :granted | :withdrawn

  @valid_statuses ~w(granted withdrawn)

  schema "consent_records" do
    field :user_id, :integer
    field :policy_key, :string
    field :policy_version, :string
    field :status, :string
    field :ip_address, :string
    field :user_agent, :string
    field :decided_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :policy_key, :policy_version, :status,
                    :ip_address, :user_agent, :decided_at])
    |> validate_required([:user_id, :policy_key, :policy_version, :status, :decided_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:policy_key, min: 1, max: 80)
    |> validate_length(:policy_version, min: 1, max: 20)
  end
end

defmodule Consent.Manager do
  @moduledoc """
  Manages user consent lifecycle for versioned policies.
  All decisions are recorded as immutable events. Querying consent returns
  the most recent record for a given user and policy key.
  """

  import Ecto.Query, warn: false

  alias Consent.{Repo, Record}

  @type context :: %{ip_address: String.t() | nil, user_agent: String.t() | nil}

  @spec grant(integer(), String.t(), String.t(), context()) ::
          {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def grant(user_id, policy_key, policy_version, ctx \\ %{})
      when is_integer(user_id) and is_binary(policy_key) and is_binary(policy_version) do
    write_record(user_id, policy_key, policy_version, :granted, ctx)
  end

  @spec withdraw(integer(), String.t(), String.t(), context()) ::
          {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def withdraw(user_id, policy_key, policy_version, ctx \\ %{})
      when is_integer(user_id) and is_binary(policy_key) and is_binary(policy_version) do
    write_record(user_id, policy_key, policy_version, :withdrawn, ctx)
  end

  @spec current_status(integer(), String.t()) :: {:ok, Record.status()} | {:error, :no_record}
  def current_status(user_id, policy_key)
      when is_integer(user_id) and is_binary(policy_key) do
    Record
    |> where([r], r.user_id == ^user_id and r.policy_key == ^policy_key)
    |> order_by([r], desc: r.decided_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :no_record}
      %Record{status: "granted"} -> {:ok, :granted}
      %Record{status: "withdrawn"} -> {:ok, :withdrawn}
    end
  end

  @spec has_granted?(integer(), String.t(), String.t()) :: boolean()
  def has_granted?(user_id, policy_key, required_version)
      when is_integer(user_id) and is_binary(policy_key) and is_binary(required_version) do
    Record
    |> where([r], r.user_id == ^user_id and r.policy_key == ^policy_key
                  and r.policy_version == ^required_version and r.status == "granted")
    |> order_by([r], desc: r.decided_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      %Record{} -> true
      nil -> false
    end
  end

  @spec history(integer(), String.t()) :: list(Record.t())
  def history(user_id, policy_key)
      when is_integer(user_id) and is_binary(policy_key) do
    Record
    |> where([r], r.user_id == ^user_id and r.policy_key == ^policy_key)
    |> order_by([r], desc: r.decided_at)
    |> Repo.all()
  end

  @spec users_with_active_consent(String.t(), String.t()) :: list(integer())
  def users_with_active_consent(policy_key, policy_version)
      when is_binary(policy_key) and is_binary(policy_version) do
    subquery =
      Record
      |> where([r], r.policy_key == ^policy_key)
      |> group_by([r], r.user_id)
      |> select([r], %{user_id: r.user_id, last_at: max(r.decided_at)})

    Record
    |> join(:inner, [r], sub in subquery(subquery),
        on: r.user_id == sub.user_id and r.decided_at == sub.last_at)
    |> where([r], r.policy_version == ^policy_version and r.status == "granted")
    |> select([r], r.user_id)
    |> Repo.all()
  end

  defp write_record(user_id, policy_key, policy_version, status, ctx) do
    attrs = %{
      user_id: user_id,
      policy_key: policy_key,
      policy_version: policy_version,
      status: Atom.to_string(status),
      ip_address: Map.get(ctx, :ip_address),
      user_agent: Map.get(ctx, :user_agent),
      decided_at: DateTime.utc_now()
    }

    attrs |> Record.changeset() |> Repo.insert()
  end
end
```
