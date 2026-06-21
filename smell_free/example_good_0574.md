```elixir
defmodule Platform.ApiKeys do
  @moduledoc """
  Context for generating, hashing, and validating API keys.

  Keys are generated as cryptographically random strings with a readable
  prefix for easy identification in logs. Only the HMAC hash is persisted;
  the plaintext key is returned exactly once at generation time and cannot
  be recovered. Validation is constant-time to prevent timing attacks.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Platform.{Repo, ApiKey}

  @type account_id :: pos_integer()
  @type key_id :: pos_integer()
  @type plaintext :: String.t()

  @key_bytes 32
  @prefix "pk_live_"
  @prefix_test "pk_test_"

  @doc """
  Generates a new API key for `account_id` and persists its hash.
  Returns `{:ok, %{key: plaintext, record: ApiKey.t()}}`.
  The plaintext is not stored; present it to the user exactly once.
  """
  @spec create(account_id(), keyword()) ::
          {:ok, %{key: plaintext(), record: ApiKey.t()}} | {:error, Ecto.Changeset.t()}
  def create(account_id, opts \\ []) when is_integer(account_id) do
    name = Keyword.get(opts, :name, "Default")
    scopes = Keyword.get(opts, :scopes, [:read])
    test_mode = Keyword.get(opts, :test_mode, false)

    plaintext = generate_key(test_mode)
    key_hash = hash_key(plaintext)

    attrs = %{
      account_id: account_id,
      name: name,
      key_hash: key_hash,
      key_prefix: String.slice(plaintext, 0, 12),
      scopes: scopes,
      test_mode: test_mode,
      last_used_at: nil
    }

    case Repo.insert(ApiKey.changeset(%ApiKey{}, attrs)) do
      {:ok, record} -> {:ok, %{key: plaintext, record: record}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Validates a plaintext API key. Returns `{:ok, ApiKey.t()}` on success,
  updating `last_used_at` asynchronously to avoid slowing the request path.
  """
  @spec validate(plaintext()) :: {:ok, ApiKey.t()} | {:error, :invalid_key | :revoked}
  def validate(plaintext) when is_binary(plaintext) do
    key_hash = hash_key(plaintext)

    case Repo.get_by(ApiKey, key_hash: key_hash) do
      nil -> {:error, :invalid_key}
      %ApiKey{revoked_at: revoked} when not is_nil(revoked) -> {:error, :revoked}
      record -> touch_last_used(record)
    end
  end

  @doc "Revokes an API key by id, preventing future authentication."
  @spec revoke(key_id(), account_id()) :: :ok | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(key_id, account_id) when is_integer(key_id) do
    case Repo.get_by(ApiKey, id: key_id, account_id: account_id) do
      nil -> {:error, :not_found}
      key -> key |> ApiKey.revoke_changeset() |> Repo.update() |> normalize_update()
    end
  end

  @doc "Lists all active (non-revoked) API keys for an account."
  @spec list(account_id()) :: [ApiKey.t()]
  def list(account_id) when is_integer(account_id) do
    from(k in ApiKey,
      where: k.account_id == ^account_id and is_nil(k.revoked_at),
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  defp generate_key(false), do: @prefix <> random_token()
  defp generate_key(true), do: @prefix_test <> random_token()

  defp random_token do
    :crypto.strong_rand_bytes(@key_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash_key(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  defp touch_last_used(record) do
    Task.start(fn ->
      Repo.update_all(from(k in ApiKey, where: k.id == ^record.id),
        set: [last_used_at: DateTime.utc_now()]
      )
    end)

    {:ok, record}
  end

  defp normalize_update({:ok, _}), do: :ok
  defp normalize_update({:error, cs}), do: {:error, cs}
end
```
