```elixir
defmodule Platform.APIKeyContext do
  @moduledoc """
  Manages API key issuance, rotation, and revocation for programmatic
  access. Keys are stored as SHA-256 hashes; the plaintext is returned
  only at creation time and never again. Keys carry a list of scope
  strings so callers can enforce least-privilege access at the middleware
  layer without hitting the database on every request.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Platform.APIKey

  @type owner_id :: String.t()
  @type key_id :: Ecto.UUID.t()
  @type scope :: String.t()
  @type create_result :: {:ok, %{plaintext: String.t(), api_key: APIKey.t()}}

  @key_prefix "sk_live_"
  @key_random_bytes 24

  @doc """
  Issues a new API key for `owner_id` with the given `scopes` and an
  optional human-readable `label`. Returns the plaintext key exactly once.
  """
  @spec create(owner_id(), [scope()], String.t()) ::
          create_result() | {:error, Ecto.Changeset.t()}
  def create(owner_id, scopes, label \\ "")
      when is_binary(owner_id) and is_list(scopes) do
    plaintext = generate_plaintext()
    hash = hash_key(plaintext)

    attrs = %{
      owner_id: owner_id,
      key_hash: hash,
      key_prefix: String.slice(plaintext, 0, 12),
      scopes: scopes,
      label: label,
      last_used_at: nil
    }

    case %APIKey{} |> APIKey.changeset(attrs) |> Repo.insert() do
      {:ok, api_key} -> {:ok, %{plaintext: plaintext, api_key: api_key}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Looks up and validates an API key string. Records the usage timestamp.
  Returns `{:error, :invalid}` for unknown or revoked keys.
  """
  @spec authenticate(String.t()) ::
          {:ok, APIKey.t()} | {:error, :invalid | :revoked}
  def authenticate(plaintext) when is_binary(plaintext) do
    hash = hash_key(plaintext)

    case Repo.get_by(APIKey, key_hash: hash) do
      nil ->
        {:error, :invalid}

      %APIKey{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %APIKey{} = key ->
        record_usage(key)
        {:ok, key}
    end
  end

  @doc "Returns true when `scope` is listed in the key's granted scopes."
  @spec has_scope?(APIKey.t(), scope()) :: boolean()
  def has_scope?(%APIKey{scopes: scopes}, scope) when is_binary(scope) do
    scope in (scopes || [])
  end

  @doc "Rotates a key: revokes the existing one and issues a new key with the same scopes."
  @spec rotate(key_id()) :: create_result() | {:error, :not_found | Ecto.Changeset.t()}
  def rotate(key_id) when is_binary(key_id) do
    case Repo.get(APIKey, key_id) do
      nil ->
        {:error, :not_found}

      %APIKey{} = existing ->
        Repo.transaction(fn ->
          revoke_key(existing)
          case create(existing.owner_id, existing.scopes || [], "Rotated from #{existing.label}") do
            {:ok, result} -> result
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
    end
  end

  @doc "Revokes an API key immediately."
  @spec revoke(key_id()) :: :ok | {:error, :not_found}
  def revoke(key_id) when is_binary(key_id) do
    case Repo.get(APIKey, key_id) do
      nil -> {:error, :not_found}
      key -> revoke_key(key)
    end
  end

  @doc "Returns all active (non-revoked) keys for `owner_id`."
  @spec list_active(owner_id()) :: [APIKey.t()]
  def list_active(owner_id) when is_binary(owner_id) do
    from(k in APIKey,
      where: k.owner_id == ^owner_id and is_nil(k.revoked_at),
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  defp generate_plaintext do
    random = :crypto.strong_rand_bytes(@key_random_bytes) |> Base.encode64(padding: false)
    "#{@key_prefix}#{random}"
  end

  defp hash_key(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  defp record_usage(%APIKey{} = key) do
    Repo.update_all(
      from(k in APIKey, where: k.id == ^key.id),
      set: [last_used_at: DateTime.utc_now()]
    )
  end

  defp revoke_key(%APIKey{} = key) do
    key
    |> APIKey.revoke_changeset(%{revoked_at: DateTime.utc_now()})
    |> Repo.update!()

    :ok
  end
end
```
