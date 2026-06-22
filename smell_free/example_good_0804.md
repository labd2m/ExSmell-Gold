```elixir
defmodule MyApp.Accounts.ApiKeyManager do
  @moduledoc """
  Creates, verifies, and revokes API keys for programmatic access to
  the platform. Keys are issued as opaque bearer tokens prefixed with
  a short human-readable identifier so users can tell which key is
  being used in their code without exposing the secret. Only the hash
  of each key is stored; the plaintext is shown exactly once at creation.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.{ApiKey, User}

  @key_prefix "sk_"
  @raw_bytes 32
  @hash_algo :sha256

  @type user_id :: String.t()
  @type raw_key :: String.t()
  @type key_id :: String.t()

  @doc """
  Issues a new API key for `user_id`. Returns `{:ok, {raw_key, api_key}}`.
  The `raw_key` must be shown to the user immediately and cannot be
  recovered later.
  """
  @spec create(user_id(), String.t(), keyword()) ::
          {:ok, {raw_key(), ApiKey.t()}} | {:error, Ecto.Changeset.t()}
  def create(user_id, label, opts \\ [])
      when is_binary(user_id) and is_binary(label) do
    raw = generate_raw_key()
    hashed = hash(raw)

    attrs = %{
      user_id: user_id,
      label: label,
      key_hash: hashed,
      key_prefix: String.slice(raw, 0, 10),
      expires_at: Keyword.get(opts, :expires_at),
      scopes: Keyword.get(opts, :scopes, [])
    }

    case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, api_key} -> {:ok, {raw, api_key}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Verifies `raw_key` and returns the owning user if the key is valid
  and not expired. Returns `{:error, :invalid}` otherwise.
  """
  @spec verify(raw_key()) :: {:ok, User.t()} | {:error, :invalid}
  def verify(raw_key) when is_binary(raw_key) do
    hashed = hash(raw_key)
    now = DateTime.utc_now()

    query =
      from k in ApiKey,
        join: u in assoc(k, :user),
        where: k.key_hash == ^hashed and (is_nil(k.expires_at) or k.expires_at > ^now),
        where: k.revoked == false,
        preload: [user: u]

    case Repo.one(query) do
      nil ->
        {:error, :invalid}

      api_key ->
        record_usage(api_key)
        {:ok, api_key.user}
    end
  end

  @doc "Revokes the API key with `key_id` belonging to `user_id`."
  @spec revoke(key_id(), user_id()) :: :ok | {:error, :not_found}
  def revoke(key_id, user_id) when is_binary(key_id) and is_binary(user_id) do
    case Repo.get_by(ApiKey, id: key_id, user_id: user_id, revoked: false) do
      nil ->
        {:error, :not_found}

      api_key ->
        api_key
        |> ApiKey.revoke_changeset()
        |> Repo.update()

        :ok
    end
  end

  @doc "Returns all active (non-revoked, non-expired) keys for `user_id`."
  @spec list(user_id()) :: [ApiKey.t()]
  def list(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    ApiKey
    |> where([k], k.user_id == ^user_id and k.revoked == false)
    |> where([k], is_nil(k.expires_at) or k.expires_at > ^now)
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  @spec generate_raw_key() :: raw_key()
  defp generate_raw_key do
    @key_prefix <> (@raw_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @spec hash(raw_key()) :: binary()
  defp hash(raw), do: :crypto.hash(@hash_algo, raw)

  @spec record_usage(ApiKey.t()) :: :ok
  defp record_usage(api_key) do
    ApiKey
    |> where([k], k.id == ^api_key.id)
    |> Repo.update_all(
      set: [last_used_at: DateTime.utc_now()],
      inc: [use_count: 1]
    )

    :ok
  end
end
```
