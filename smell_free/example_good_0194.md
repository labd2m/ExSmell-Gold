# File: `example_good_194.md`

```elixir
defmodule Auth.ApiKeyManager do
  @moduledoc """
  Manages the full lifecycle of API keys: creation, verification,
  rotation, and revocation.

  Keys are stored as HMAC-SHA256 hashes; the plaintext value is
  returned once at creation time and never retrievable again.
  Callers must present the plaintext key for verification.
  """

  import Ecto.Query, warn: false

  alias Auth.{ApiKey, Repo}
  alias Accounts.User

  @prefix_length 8
  @key_byte_length 32

  @type key_result :: {:ok, %{key: String.t(), record: ApiKey.t()}} | {:error, term()}
  @type verify_result :: {:ok, ApiKey.t()} | {:error, :invalid | :revoked | :expired}

  @doc """
  Generates a new API key for the given user with an optional name
  and expiry date.

  Returns `{:ok, %{key: plaintext, record: api_key}}`. The `key` field
  contains the only opportunity to retrieve the plaintext value.
  """
  @spec create(User.t(), String.t(), Date.t() | nil) :: key_result()
  def create(%User{} = user, name, expires_on \\ nil)
      when is_binary(name) and byte_size(name) > 0 do
    plaintext = generate_plaintext()
    prefix = String.slice(plaintext, 0, @prefix_length)
    key_hash = hash_key(plaintext)

    attrs = %{
      user_id: user.id,
      name: name,
      prefix: prefix,
      key_hash: key_hash,
      expires_on: expires_on,
      status: :active
    }

    case attrs |> ApiKey.changeset() |> Repo.insert() do
      {:ok, record} -> {:ok, %{key: plaintext, record: record}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Verifies a plaintext API key and returns the associated record if
  valid, active, and not expired.
  """
  @spec verify(String.t()) :: verify_result()
  def verify(plaintext) when is_binary(plaintext) and byte_size(plaintext) > @prefix_length do
    prefix = String.slice(plaintext, 0, @prefix_length)

    case lookup_by_prefix(prefix) do
      nil -> {:error, :invalid}
      key_record -> evaluate_key(key_record, plaintext)
    end
  end

  def verify(_plaintext), do: {:error, :invalid}

  @doc """
  Revokes an API key immediately.

  Returns `{:ok, api_key}` or `{:error, :already_revoked}`.
  """
  @spec revoke(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, :already_revoked}
  def revoke(%ApiKey{status: :revoked}), do: {:error, :already_revoked}

  def revoke(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.revoke_changeset(%{status: :revoked, revoked_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Rotates an API key by revoking the existing one and issuing a new key
  with the same name and expiry, in a single transaction.
  """
  @spec rotate(ApiKey.t()) :: key_result()
  def rotate(%ApiKey{status: :active, user_id: uid, name: name, expires_on: exp} = existing) do
    Repo.transaction(fn ->
      {:ok, _} = revoke(existing)
      plaintext = generate_plaintext()
      prefix = String.slice(plaintext, 0, @prefix_length)

      record =
        %{user_id: uid, name: name, prefix: prefix, key_hash: hash_key(plaintext),
          expires_on: exp, status: :active}
        |> ApiKey.changeset()
        |> Repo.insert!()

      %{key: plaintext, record: record}
    end)
  end

  def rotate(%ApiKey{}), do: {:error, :not_active}

  @doc """
  Lists all active API keys for a user.
  """
  @spec list_active(User.t()) :: [ApiKey.t()]
  def list_active(%User{id: user_id}) do
    ApiKey
    |> where([k], k.user_id == ^user_id and k.status == :active)
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  defp lookup_by_prefix(prefix) do
    ApiKey
    |> where([k], k.prefix == ^prefix and k.status == :active)
    |> Repo.one()
  end

  defp evaluate_key(%ApiKey{status: :revoked}, _plaintext), do: {:error, :revoked}

  defp evaluate_key(%ApiKey{expires_on: exp} = key, plaintext) when not is_nil(exp) do
    if Date.compare(Date.utc_today(), exp) == :gt do
      {:error, :expired}
    else
      verify_hash(key, plaintext)
    end
  end

  defp evaluate_key(%ApiKey{} = key, plaintext), do: verify_hash(key, plaintext)

  defp verify_hash(%ApiKey{key_hash: stored_hash} = key, plaintext) do
    candidate = hash_key(plaintext)

    if :crypto.hash_equals(stored_hash, candidate) do
      {:ok, key}
    else
      {:error, :invalid}
    end
  end

  defp generate_plaintext do
    :crypto.strong_rand_bytes(@key_byte_length) |> Base.url_encode64(padding: false)
  end

  defp hash_key(plaintext) do
    :crypto.hash(:sha256, plaintext)
  end
end
```
