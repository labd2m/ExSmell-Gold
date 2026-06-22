```elixir
defmodule ApiKeys.KeyManager do
  @moduledoc """
  Issues, rotates, and revokes scoped API keys for service-to-service
  authentication. Keys are stored as salted hashes; only the plaintext
  is returned at creation time and never persisted.
  """

  alias ApiKeys.{Repo, ApiKey, KeyHasher}
  import Ecto.Query

  @key_prefix "sk"
  @key_bytes 32

  @type owner_id :: String.t()
  @type scope :: String.t()

  @type issue_result :: %{
          key_id: String.t(),
          plaintext: String.t(),
          scopes: [scope()],
          expires_at: DateTime.t() | nil
        }

  @spec issue(owner_id(), [scope()], keyword()) ::
          {:ok, issue_result()} | {:error, Ecto.Changeset.t()}
  def issue(owner_id, scopes, opts \\ []) when is_binary(owner_id) and is_list(scopes) do
    plaintext = generate_key()
    hash = KeyHasher.hash(plaintext)
    expires_at = Keyword.get(opts, :expires_at)
    label = Keyword.get(opts, :label)

    params = %{
      owner_id: owner_id,
      key_hash: hash,
      key_prefix: String.slice(plaintext, 0, 12),
      scopes: scopes,
      expires_at: expires_at,
      label: label
    }

    case %ApiKey{} |> ApiKey.creation_changeset(params) |> Repo.insert() do
      {:ok, key} ->
        {:ok,
         %{
           key_id: key.id,
           plaintext: plaintext,
           scopes: key.scopes,
           expires_at: key.expires_at
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec verify(String.t()) :: {:ok, ApiKey.t()} | {:error, :invalid | :expired | :revoked}
  def verify(plaintext) when is_binary(plaintext) do
    prefix = String.slice(plaintext, 0, 12)

    case Repo.get_by(ApiKey, key_prefix: prefix, revoked: false) do
      nil ->
        KeyHasher.dummy_check()
        {:error, :invalid}

      key ->
        check_key(key, plaintext)
    end
  end

  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(key_id) when is_binary(key_id) do
    case Repo.get(ApiKey, key_id) do
      nil ->
        {:error, :not_found}

      key ->
        key
        |> ApiKey.revocation_changeset(%{revoked: true, revoked_at: DateTime.utc_now()})
        |> Repo.update()

        :ok
    end
  end

  @spec list_for_owner(owner_id()) :: [ApiKey.t()]
  def list_for_owner(owner_id) when is_binary(owner_id) do
    from(k in ApiKey,
      where: k.owner_id == ^owner_id and k.revoked == false,
      order_by: [desc: k.inserted_at],
      select: %{id: k.id, label: k.label, scopes: k.scopes,
                key_prefix: k.key_prefix, expires_at: k.expires_at,
                inserted_at: k.inserted_at}
    )
    |> Repo.all()
  end

  @spec check_key(ApiKey.t(), String.t()) ::
          {:ok, ApiKey.t()} | {:error, :invalid | :expired}
  defp check_key(key, plaintext) do
    cond do
      not KeyHasher.valid?(plaintext, key.key_hash) ->
        {:error, :invalid}

      not is_nil(key.expires_at) and
          DateTime.compare(key.expires_at, DateTime.utc_now()) != :gt ->
        {:error, :expired}

      true ->
        {:ok, key}
    end
  end

  @spec generate_key() :: String.t()
  defp generate_key do
    random = :crypto.strong_rand_bytes(@key_bytes) |> Base.url_encode64(padding: false)
    "#{@key_prefix}_#{random}"
  end
end
```
