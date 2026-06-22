```elixir
defmodule ApiKeys.Manager do
  @moduledoc """
  Context for issuing, rotating, and revoking API keys for service accounts.

  Keys are stored as hashed values; the plaintext is only returned at issuance
  time. All lookups compare against the stored hash.
  """

  import Ecto.Query

  alias ApiKeys.Repo
  alias ApiKeys.Manager.{ApiKey, KeyHasher, PrefixGenerator}

  @key_bytes 32

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Issues a new API key for a service account.

  Returns `{:ok, %{key: plaintext, record: api_key}}`. The plaintext is not
  retrievable after this call.
  """
  @spec issue(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(account_id, name, opts \\ [])
      when is_binary(account_id) and is_binary(name) and name != "" do
    plaintext = generate_key()
    prefix = PrefixGenerator.extract(plaintext)
    hash = KeyHasher.hash(plaintext)
    expires_at = Keyword.get(opts, :expires_at)

    attrs = %{
      account_id: account_id,
      name: name,
      prefix: prefix,
      key_hash: hash,
      expires_at: expires_at,
      status: :active
    }

    with {:ok, record} <- %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, %{key: plaintext, record: record}}
    end
  end

  @doc """
  Authenticates a raw API key string, returning its associated record if valid and active.
  """
  @spec authenticate(String.t()) :: {:ok, ApiKey.t()} | {:error, :invalid | :expired | :revoked}
  def authenticate(raw_key) when is_binary(raw_key) do
    prefix = PrefixGenerator.extract(raw_key)

    case Repo.get_by(ApiKey, prefix: prefix, status: :active) do
      nil ->
        {:error, :invalid}

      %ApiKey{} = record ->
        verify_key(raw_key, record)
    end
  end

  @doc """
  Revokes an API key immediately, preventing further authentication.
  """
  @spec revoke(String.t(), String.t()) :: result(ApiKey.t())
  def revoke(account_id, key_id) when is_binary(account_id) and is_binary(key_id) do
    case Repo.get_by(ApiKey, id: key_id, account_id: account_id) do
      nil ->
        {:error, "key not found"}

      %ApiKey{status: :revoked} ->
        {:error, "key already revoked"}

      %ApiKey{} = key ->
        key
        |> ApiKey.revoke_changeset(%{status: :revoked, revoked_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc """
  Rotates an existing key, revoking it and issuing a new one atomically.
  """
  @spec rotate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rotate(account_id, key_id) when is_binary(account_id) and is_binary(key_id) do
    Repo.transaction(fn ->
      with {:ok, old_key} <- fetch_active_key(account_id, key_id),
           {:ok, _} <- revoke(account_id, key_id),
           {:ok, result} <- issue(account_id, "#{old_key.name} (rotated)") do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Lists all API keys for a given account, excluding revoked keys by default.
  """
  @spec list(String.t(), keyword()) :: [ApiKey.t()]
  def list(account_id, opts \\ []) when is_binary(account_id) do
    include_revoked = Keyword.get(opts, :include_revoked, false)

    ApiKey
    |> where([k], k.account_id == ^account_id)
    |> then(fn q ->
      if include_revoked, do: q, else: where(q, [k], k.status != :revoked)
    end)
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  # --- private helpers ---

  defp generate_key do
    @key_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp verify_key(raw_key, %ApiKey{key_hash: stored_hash, expires_at: exp} = record) do
    cond do
      not KeyHasher.verify(raw_key, stored_hash) -> {:error, :invalid}
      expired?(exp) -> {:error, :expired}
      true -> {:ok, record}
    end
  end

  defp expired?(nil), do: false
  defp expired?(exp), do: DateTime.compare(exp, DateTime.utc_now()) == :lt

  defp fetch_active_key(account_id, key_id) do
    case Repo.get_by(ApiKey, id: key_id, account_id: account_id, status: :active) do
      nil -> {:error, "active key not found"}
      key -> {:ok, key}
    end
  end
end

defmodule ApiKeys.Manager.PrefixGenerator do
  @moduledoc false

  @prefix_length 8

  @spec extract(String.t()) :: String.t()
  def extract(key) when is_binary(key), do: String.slice(key, 0, @prefix_length)
end

defmodule ApiKeys.Manager.KeyHasher do
  @moduledoc false

  @spec hash(String.t()) :: String.t()
  def hash(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(plaintext, stored_hash) when is_binary(plaintext) and is_binary(stored_hash) do
    Plug.Crypto.secure_compare(hash(plaintext), stored_hash)
  end
end
```
