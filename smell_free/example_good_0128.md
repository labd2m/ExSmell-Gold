```elixir
defmodule MyApp.Accounts.SessionToken do
  @moduledoc """
  Issues, verifies, and revokes opaque session tokens for web authentication.
  Tokens are stored as hashed values in the `session_tokens` table so that
  a database compromise does not expose raw bearer credentials.

  Token contexts are used to scope tokens to their intended purpose
  (`:session`, `:password_reset`, `:email_confirmation`) so that a token
  issued for one purpose cannot be reused for another.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.User

  @hash_algorithm :sha256
  @rand_size 32
  @session_validity_days 60
  @reset_validity_hours 1
  @confirm_validity_hours 24

  @type context :: :session | :password_reset | :email_confirmation

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "session_tokens" do
    field :token, :binary
    field :context, Ecto.Enum, values: [:session, :password_reset, :email_confirmation]
    belongs_to :user, User, type: :binary_id

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc """
  Builds and persists a new token for `user` under `context`.
  Returns `{raw_token, schema_struct}`.
  The `raw_token` must be delivered to the user; only the hash is stored.
  """
  @spec build_and_persist(User.t(), context()) ::
          {:ok, {binary(), __MODULE__.t()}} | {:error, Ecto.Changeset.t()}
  def build_and_persist(%User{} = user, context) do
    raw_token = :crypto.strong_rand_bytes(@rand_size)

    changeset =
      %__MODULE__{}
      |> cast(%{token: hash(raw_token), context: context, user_id: user.id}, [
        :token,
        :context,
        :user_id
      ])
      |> validate_required([:token, :context, :user_id])

    case Repo.insert(changeset) do
      {:ok, schema} -> {:ok, {raw_token, schema}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Verifies `raw_token` for `context` and returns the owning user if valid.
  Returns `{:error, :invalid}` when the token is missing, expired, or
  scoped to a different context.
  """
  @spec verify(binary(), context()) :: {:ok, User.t()} | {:error, :invalid}
  def verify(raw_token, context) when is_binary(raw_token) do
    hashed = hash(raw_token)
    cutoff = validity_cutoff(context)

    query =
      from t in __MODULE__,
        join: u in assoc(t, :user),
        where:
          t.token == ^hashed and
            t.context == ^context and
            t.inserted_at > ^cutoff,
        select: u

    case Repo.one(query) do
      nil -> {:error, :invalid}
      user -> {:ok, user}
    end
  end

  @doc "Deletes a single token by its raw value."
  @spec revoke(binary()) :: :ok
  def revoke(raw_token) when is_binary(raw_token) do
    hashed = hash(raw_token)
    Repo.delete_all(from t in __MODULE__, where: t.token == ^hashed)
    :ok
  end

  @doc "Deletes all tokens belonging to `user` under `context`."
  @spec revoke_all(User.t(), context()) :: :ok
  def revoke_all(%User{id: user_id}, context) do
    Repo.delete_all(
      from t in __MODULE__, where: t.user_id == ^user_id and t.context == ^context
    )

    :ok
  end

  @spec hash(binary()) :: binary()
  defp hash(data), do: :crypto.hash(@hash_algorithm, data)

  @spec validity_cutoff(context()) :: DateTime.t()
  defp validity_cutoff(:session) do
    DateTime.add(DateTime.utc_now(), -@session_validity_days, :day)
  end

  defp validity_cutoff(:password_reset) do
    DateTime.add(DateTime.utc_now(), -@reset_validity_hours, :hour)
  end

  defp validity_cutoff(:email_confirmation) do
    DateTime.add(DateTime.utc_now(), -@confirm_validity_hours, :hour)
  end
end
```
