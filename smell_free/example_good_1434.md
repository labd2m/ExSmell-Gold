```elixir
defmodule Privacy.ConsentManager do
  @moduledoc """
  Records and enforces user consent for data processing purposes.
  Consent grants and withdrawals are persisted as an immutable audit log,
  with the current effective state derived by replaying the log.
  """

  alias Privacy.{Repo, ConsentRecord}
  import Ecto.Query

  @type user_id :: String.t()
  @type purpose :: :analytics | :marketing | :personalisation | :third_party_sharing
  @type consent_status :: :granted | :withdrawn | :not_set

  @type consent_state :: %{purpose() => consent_status()}

  @all_purposes [:analytics, :marketing, :personalisation, :third_party_sharing]

  @spec grant(user_id(), purpose(), map()) ::
          {:ok, ConsentRecord.t()} | {:error, :invalid_purpose | Ecto.Changeset.t()}
  def grant(user_id, purpose, metadata \\ %{}) when is_binary(user_id) do
    with :ok <- validate_purpose(purpose) do
      record_event(user_id, purpose, :granted, metadata)
    end
  end

  @spec withdraw(user_id(), purpose(), map()) ::
          {:ok, ConsentRecord.t()} | {:error, :invalid_purpose | Ecto.Changeset.t()}
  def withdraw(user_id, purpose, metadata \\ %{}) when is_binary(user_id) do
    with :ok <- validate_purpose(purpose) do
      record_event(user_id, purpose, :withdrawn, metadata)
    end
  end

  @spec consented?(user_id(), purpose()) :: boolean()
  def consented?(user_id, purpose) when is_binary(user_id) and is_atom(purpose) do
    current_state(user_id)
    |> Map.get(purpose, :not_set)
    |> Kernel.==(:granted)
  end

  @spec current_state(user_id()) :: consent_state()
  def current_state(user_id) when is_binary(user_id) do
    records = latest_per_purpose(user_id)

    Map.new(@all_purposes, fn purpose ->
      status =
        case Enum.find(records, &(&1.purpose == to_string(purpose))) do
          nil -> :not_set
          record -> String.to_existing_atom(record.status)
        end

      {purpose, status}
    end)
  end

  @spec history(user_id(), keyword()) :: [ConsentRecord.t()]
  def history(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)
    purpose = Keyword.get(opts, :purpose)

    from(c in ConsentRecord, where: c.user_id == ^user_id, order_by: [desc: c.inserted_at], limit: ^limit)
    |> apply_purpose_filter(purpose)
    |> Repo.all()
  end

  @spec validate_purpose(purpose()) :: :ok | {:error, :invalid_purpose}
  defp validate_purpose(purpose) do
    if purpose in @all_purposes, do: :ok, else: {:error, :invalid_purpose}
  end

  @spec record_event(user_id(), purpose(), atom(), map()) ::
          {:ok, ConsentRecord.t()} | {:error, Ecto.Changeset.t()}
  defp record_event(user_id, purpose, status, metadata) do
    %ConsentRecord{}
    |> ConsentRecord.creation_changeset(%{
      user_id: user_id,
      purpose: to_string(purpose),
      status: to_string(status),
      metadata: metadata,
      recorded_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec latest_per_purpose(user_id()) :: [ConsentRecord.t()]
  defp latest_per_purpose(user_id) do
    from(c in ConsentRecord,
      where: c.user_id == ^user_id,
      distinct: c.purpose,
      order_by: [asc: c.purpose, desc: c.inserted_at]
    )
    |> Repo.all()
  end

  @spec apply_purpose_filter(Ecto.Query.t(), purpose() | nil) :: Ecto.Query.t()
  defp apply_purpose_filter(query, nil), do: query

  defp apply_purpose_filter(query, purpose) do
    from(c in query, where: c.purpose == ^to_string(purpose))
  end
end
```
