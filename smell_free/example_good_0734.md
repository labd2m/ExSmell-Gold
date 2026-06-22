```elixir
defmodule Auth.ResetToken do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t(),
          token_hash: String.t(),
          expires_at: DateTime.t(),
          consumed_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "password_reset_tokens" do
    field :user_id, :binary_id
    field :token_hash, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(token, params) do
    token
    |> cast(params, [:user_id, :token_hash, :expires_at])
    |> validate_required([:user_id, :token_hash, :expires_at])
  end
end

defmodule Auth.PasswordReset do
  @moduledoc """
  Manages the lifecycle of single-use, time-limited password reset tokens.

  Tokens are generated as a URL-safe random byte string; only a SHA-256
  digest is stored in the database so that a database compromise does not
  expose usable reset links. Tokens are consumed atomically on successful
  verification, preventing replay even under concurrent requests.
  """

  import Ecto.Query, warn: false

  alias Auth.{Repo, ResetToken}

  @token_bytes 32
  @default_ttl_minutes 60

  @spec generate(Ecto.UUID.t(), pos_integer()) :: {:ok, String.t(), ResetToken.t()} | {:error, Ecto.Changeset.t()}
  def generate(user_id, ttl_minutes \\ @default_ttl_minutes) when is_binary(user_id) do
    raw_token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    token_hash = hash(raw_token)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_minutes * 60, :second)

    params = %{user_id: user_id, token_hash: token_hash, expires_at: expires_at}

    case %ResetToken{} |> ResetToken.creation_changeset(params) |> Repo.insert() do
      {:ok, record} -> {:ok, raw_token, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec verify_and_consume(String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid | :expired | :already_used}
  def verify_and_consume(raw_token) when is_binary(raw_token) do
    token_hash = hash(raw_token)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      record =
        ResetToken
        |> where([t], t.token_hash == ^token_hash and is_nil(t.consumed_at))
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()

      case record do
        nil ->
          Repo.rollback(:invalid)

        %ResetToken{expires_at: exp} when exp < ^now ->
          Repo.rollback(:expired)

        %ResetToken{} = r ->
          r
          |> Ecto.Changeset.change(consumed_at: now)
          |> Repo.update!()

          r.user_id
      end
    end)
    |> case do
      {:ok, user_id} -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec purge_expired() :: {non_neg_integer(), nil}
  def purge_expired do
    now = DateTime.utc_now()
    Repo.delete_all(from t in ResetToken, where: t.expires_at < ^now)
  end

  defp hash(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
```
