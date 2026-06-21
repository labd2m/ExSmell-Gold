```elixir
defmodule Accounts.SessionManager do
  @moduledoc """
  Creates, validates, and revokes user sessions backed by the database.
  Session tokens are cryptographically secure random strings. The manager
  enforces a maximum concurrent session limit per user, evicting the oldest
  session when the limit is exceeded. All public functions return tagged
  result tuples; no exceptions escape the module boundary.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.Session

  @type user_id :: String.t()
  @type token :: String.t()
  @type session_context :: %{ip_address: String.t() | nil, user_agent: String.t() | nil}

  @token_bytes 32
  @max_sessions_per_user 5
  @default_ttl_days 30

  @doc "Creates a new session for `user_id`, evicting the oldest when at capacity."
  @spec create(user_id(), session_context()) ::
          {:ok, %{token: token(), session: Session.t()}} | {:error, Ecto.Changeset.t()}
  def create(user_id, ctx \ %{}) when is_binary(user_id) do
    Repo.transaction(fn ->
      evict_if_at_capacity(user_id)
      token = generate_token()
      expires_at = DateTime.add(DateTime.utc_now(), @default_ttl_days * 86_400, :second)

      attrs = %{
        user_id: user_id,
        token_hash: hash_token(token),
        expires_at: expires_at,
        ip_address: Map.get(ctx, :ip_address),
        user_agent: Map.get(ctx, :user_agent)
      }

      case %Session{} |> Session.changeset(attrs) |> Repo.insert() do
        {:ok, session} -> %{token: token, session: session}
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc "Validates `token` and returns the associated session if valid and unexpired."
  @spec validate(token()) :: {:ok, Session.t()} | {:error, :invalid | :expired}
  def validate(token) when is_binary(token) do
    hash = hash_token(token)

    case Repo.get_by(Session, token_hash: hash) do
      nil ->
        {:error, :invalid}

      %Session{expires_at: exp} = session ->
        if DateTime.compare(DateTime.utc_now(), exp) == :lt do
          {:ok, session}
        else
          {:error, :expired}
        end
    end
  end

  @doc "Revokes a single session by token."
  @spec revoke(token()) :: :ok | {:error, :not_found}
  def revoke(token) when is_binary(token) do
    hash = hash_token(token)

    case Repo.delete_all(from(s in Session, where: s.token_hash == ^hash)) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc "Revokes all sessions for `user_id`."
  @spec revoke_all(user_id()) :: {:ok, non_neg_integer()}
  def revoke_all(user_id) when is_binary(user_id) do
    {count, _} = Repo.delete_all(from(s in Session, where: s.user_id == ^user_id))
    {:ok, count}
  end

  @doc "Returns all active (unexpired) sessions for `user_id`."
  @spec list_active(user_id()) :: [Session.t()]
  def list_active(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()
    from(s in Session, where: s.user_id == ^user_id and s.expires_at > ^now,
      order_by: [asc: s.inserted_at])
    |> Repo.all()
  end

  defp evict_if_at_capacity(user_id) do
    sessions = list_active(user_id)

    if length(sessions) >= @max_sessions_per_user do
      oldest = List.first(sessions)
      Repo.delete!(oldest)
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
```
