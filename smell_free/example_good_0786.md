```elixir
defmodule Auth.ApiKeys do
  @moduledoc """
  Manages scoped API keys for programmatic access. Each key is associated
  with an owner, carries a list of permission scopes, and has an optional
  expiry. The raw key is shown only once at creation time; only the hashed
  value is stored so a database breach does not expose usable credentials.
  Key lookup uses a constant-time comparison to resist timing attacks.
  """

  alias Auth.{ApiKey, Repo}
  import Ecto.Query

  require Logger

  @type owner_id :: binary()
  @type scope :: binary()
  @type key_attrs :: %{
          required(:name) => binary(),
          required(:owner_id) => owner_id(),
          required(:scopes) => [scope()],
          optional(:expires_at) => DateTime.t() | nil
        }

  @key_prefix "ak_live_"
  @key_bytes 32
  @hash_alg :sha256

  @doc """
  Creates a new API key. Returns `{:ok, %{key: raw_key, record: api_key}}`
  where `raw_key` is the only time the plaintext secret is available.
  """
  @spec create(key_attrs()) :: {:ok, %{key: binary(), record: ApiKey.t()}} | {:error, term()}
  def create(%{owner_id: owner_id, name: name, scopes: scopes} = attrs)
      when is_binary(owner_id) and is_binary(name) and is_list(scopes) do
    raw = generate_key()
    hash = hash_key(raw)

    changeset =
      ApiKey.changeset(%ApiKey{}, %{
        name: name,
        owner_id: owner_id,
        scopes: scopes,
        key_hash: hash,
        key_prefix: String.slice(raw, 0, 12),
        expires_at: Map.get(attrs, :expires_at)
      })

    case Repo.insert(changeset) do
      {:ok, record} ->
        Logger.info("API key created", owner_id: owner_id, key_id: record.id, scopes: scopes)
        {:ok, %{key: raw, record: record}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Authenticates a raw API key string. Returns `{:ok, api_key}` when the key
  is valid, active, and not expired. Returns `{:error, reason}` otherwise.
  Performs constant-time hash comparison after narrowing candidates by prefix.
  """
  @spec authenticate(binary()) :: {:ok, ApiKey.t()} | {:error, :invalid | :expired | :revoked}
  def authenticate(raw_key) when is_binary(raw_key) do
    with :ok <- validate_format(raw_key),
         prefix = String.slice(raw_key, 0, 12),
         {:ok, candidate} <- find_by_prefix(prefix),
         :ok <- verify_hash(raw_key, candidate.key_hash),
         :ok <- check_expiry(candidate),
         :ok <- check_active(candidate) do
      touch_last_used(candidate)
      {:ok, candidate}
    end
  end

  @doc """
  Returns `true` when `api_key` carries the requested `scope`.
  Supports wildcard scopes such as `"documents:*"`.
  """
  @spec has_scope?(ApiKey.t(), scope()) :: boolean()
  def has_scope?(%ApiKey{scopes: scopes}, required_scope) when is_binary(required_scope) do
    Enum.any?(scopes, fn granted ->
      granted == required_scope or wildcard_match?(granted, required_scope)
    end)
  end

  @doc """
  Revokes `api_key_id` immediately. Revoked keys fail authentication.
  """
  @spec revoke(binary(), owner_id()) :: :ok | {:error, :not_found | :forbidden}
  def revoke(api_key_id, requesting_owner_id)
      when is_binary(api_key_id) and is_binary(requesting_owner_id) do
    case Repo.get(ApiKey, api_key_id) do
      nil ->
        {:error, :not_found}

      %ApiKey{owner_id: ^requesting_owner_id} = key ->
        key |> ApiKey.revoke_changeset() |> Repo.update()
        Logger.info("API key revoked", key_id: api_key_id, owner_id: requesting_owner_id)
        :ok

      %ApiKey{} ->
        {:error, :forbidden}
    end
  end

  @doc """
  Lists all active API keys for `owner_id`, ordered by creation date.
  Raw secrets are never included in list results.
  """
  @spec list_for_owner(owner_id()) :: [ApiKey.t()]
  def list_for_owner(owner_id) when is_binary(owner_id) do
    ApiKey
    |> where([k], k.owner_id == ^owner_id and k.revoked == false)
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_key do
    @key_prefix <> (:crypto.strong_rand_bytes(@key_bytes) |> Base.url_encode64(padding: false))
  end

  defp hash_key(raw) do
    :crypto.hash(@hash_alg, raw) |> Base.encode16(case: :lower)
  end

  defp validate_format(key) do
    if String.starts_with?(key, @key_prefix) and byte_size(key) > byte_size(@key_prefix) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp find_by_prefix(prefix) do
    case Repo.get_by(ApiKey, key_prefix: prefix) do
      nil -> {:error, :invalid}
      key -> {:ok, key}
    end
  end

  defp verify_hash(raw, stored_hash) do
    computed = hash_key(raw)

    if Plug.Crypto.secure_compare(computed, stored_hash) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp check_expiry(%ApiKey{expires_at: nil}), do: :ok

  defp check_expiry(%ApiKey{expires_at: exp}) do
    if DateTime.compare(DateTime.utc_now(), exp) == :lt, do: :ok, else: {:error, :expired}
  end

  defp check_active(%ApiKey{revoked: false}), do: :ok
  defp check_active(%ApiKey{revoked: true}), do: {:error, :revoked}

  defp touch_last_used(key) do
    key |> ApiKey.touch_changeset() |> Repo.update()
  end

  defp wildcard_match?(granted, required) do
    case String.split(granted, ":") do
      [domain, "*"] -> String.starts_with?(required, domain <> ":")
      _ -> false
    end
  end
end
```
