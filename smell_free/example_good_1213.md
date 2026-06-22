```elixir
defmodule MyApp.Compliance.ConsentManager do
  @moduledoc """
  Records and verifies explicit user consent for data processing purposes
  under GDPR and similar frameworks. Each consent record is immutable and
  timestamped; withdrawing consent inserts a revocation record rather than
  deleting the grant, preserving the full audit trail required by regulation.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Compliance.ConsentRecord

  @type user_id :: String.t()
  @type purpose :: String.t()
  @type version :: String.t()

  @doc """
  Records explicit consent from `user_id` for `purpose` under the given
  policy `version`. Returns `{:error, :already_granted}` when an active
  consent for the same purpose and version already exists.
  """
  @spec grant(user_id(), purpose(), version(), map()) ::
          {:ok, ConsentRecord.t()} | {:error, :already_granted} | {:error, Ecto.Changeset.t()}
  def grant(user_id, purpose, version, metadata \\ %{})
      when is_binary(user_id) and is_binary(purpose) and is_binary(version) do
    if active_consent?(user_id, purpose, version) do
      {:error, :already_granted}
    else
      %ConsentRecord{}
      |> ConsentRecord.changeset(%{
        user_id: user_id,
        purpose: purpose,
        policy_version: version,
        action: :granted,
        metadata: metadata,
        occurred_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  @doc """
  Revokes consent from `user_id` for `purpose`. Inserts a revocation
  record without modifying the original grant.
  """
  @spec revoke(user_id(), purpose(), String.t() | nil) ::
          :ok | {:error, :no_active_consent} | {:error, Ecto.Changeset.t()}
  def revoke(user_id, purpose, reason \\ nil)
      when is_binary(user_id) and is_binary(purpose) do
    case latest_grant(user_id, purpose) do
      nil ->
        {:error, :no_active_consent}

      grant ->
        result =
          %ConsentRecord{}
          |> ConsentRecord.changeset(%{
            user_id: user_id,
            purpose: purpose,
            policy_version: grant.policy_version,
            action: :revoked,
            metadata: %{reason: reason, revoked_grant_id: grant.id},
            occurred_at: DateTime.utc_now()
          })
          |> Repo.insert()

        case result do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end
    end
  end

  @doc "Returns `true` when `user_id` has active consent for `purpose`."
  @spec consented?(user_id(), purpose()) :: boolean()
  def consented?(user_id, purpose) when is_binary(user_id) and is_binary(purpose) do
    case latest_record(user_id, purpose) do
      nil -> false
      %{action: :granted} -> true
      %{action: :revoked} -> false
    end
  end

  @doc "Returns the full consent history for `user_id`, newest first."
  @spec history(user_id()) :: [ConsentRecord.t()]
  def history(user_id) when is_binary(user_id) do
    ConsentRecord
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.occurred_at)
    |> Repo.all()
  end

  @doc "Returns all purposes for which `user_id` currently has active consent."
  @spec active_purposes(user_id()) :: [purpose()]
  def active_purposes(user_id) when is_binary(user_id) do
    ConsentRecord
    |> where([c], c.user_id == ^user_id)
    |> distinct([c], c.purpose)
    |> order_by([c], desc: c.occurred_at)
    |> Repo.all()
    |> Enum.filter(&(&1.action == :granted))
    |> Enum.map(& &1.purpose)
  end

  @spec active_consent?(user_id(), purpose(), version()) :: boolean()
  defp active_consent?(user_id, purpose, version) do
    ConsentRecord
    |> where([c], c.user_id == ^user_id and c.purpose == ^purpose and
               c.policy_version == ^version and c.action == :granted)
    |> Repo.exists?()
  end

  @spec latest_grant(user_id(), purpose()) :: ConsentRecord.t() | nil
  defp latest_grant(user_id, purpose) do
    ConsentRecord
    |> where([c], c.user_id == ^user_id and c.purpose == ^purpose and c.action == :granted)
    |> order_by([c], desc: c.occurred_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec latest_record(user_id(), purpose()) :: ConsentRecord.t() | nil
  defp latest_record(user_id, purpose) do
    ConsentRecord
    |> where([c], c.user_id == ^user_id and c.purpose == ^purpose)
    |> order_by([c], desc: c.occurred_at)
    |> limit(1)
    |> Repo.one()
  end
end
```
