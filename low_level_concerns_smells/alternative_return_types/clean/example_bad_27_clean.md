```elixir
defmodule MyApp.IAM.ApiKeyManager do
  @moduledoc """
  Issues, rotates, and revokes API keys for service accounts and integrations.
  Keys are stored hashed; the raw secret is returned only at issuance time
  and never retrievable again.
  """

  alias MyApp.IAM.ApiKey
  alias MyApp.IAM.ApiKeyStore
  alias MyApp.IAM.ScopeValidator
  alias MyApp.IAM.AuditLog

  @key_prefix "sk_live_"
  @test_key_prefix "sk_test_"
  @default_ttl_days 365
  @max_keys_per_account 10

  defstruct [
    :id, :account_id, :prefix, :key_hash,
    :scopes, :label, :expires_at,
    :last_used_at, :revoked, :created_at
  ]

  def list(account_id) do
    ApiKeyStore.list_for_account(account_id)
    |> Enum.map(&sanitize/1)
  end

  def issue(account_id, opts \\ []) when is_list(opts) do
    include = Keyword.get(opts, :include, :key_only)
    scopes = Keyword.get(opts, :scopes, [:read])
    label = Keyword.get(opts, :label, "Default")
    ttl_days = Keyword.get(opts, :ttl_days, @default_ttl_days)
    test_mode = Keyword.get(opts, :test_mode, false)

    with :ok <- ScopeValidator.validate_all(scopes),
         :ok <- check_key_limit(account_id) do
      prefix = if test_mode, do: @test_key_prefix, else: @key_prefix
      raw_key = prefix <> generate_secret(32)
      key_hash = hash_key(raw_key)
      signing_secret = generate_secret(24)

      credential = %__MODULE__{
        id: generate_id(),
        account_id: account_id,
        prefix: prefix,
        key_hash: key_hash,
        scopes: scopes,
        label: label,
        expires_at: Date.add(Date.utc_today(), ttl_days) |> DateTime.new!(~T[23:59:59]),
        last_used_at: nil,
        revoked: false,
        created_at: DateTime.utc_now()
      }

      ApiKeyStore.insert!(credential)
      AuditLog.record(:api_key_issued, %{account_id: account_id, key_id: credential.id})

      case include do
        :key_only ->
          raw_key

        :key_and_secret ->
          {raw_key, signing_secret}

        :credential ->
          {:ok, %{credential | key_hash: raw_key}}
      end
    end
  end

  def revoke(key_id, account_id) do
    with {:ok, key} <- ApiKeyStore.fetch(key_id, account_id) do
      ApiKeyStore.update!(%{key | revoked: true})
      AuditLog.record(:api_key_revoked, %{account_id: account_id, key_id: key_id})
      :ok
    end
  end

  def rotate(key_id, account_id, opts \\ []) do
    with :ok <- revoke(key_id, account_id) do
      issue(account_id, opts)
    end
  end

  def verify(raw_key) do
    hash = hash_key(raw_key)
    ApiKeyStore.find_by_hash(hash)
  end

  defp check_key_limit(account_id) do
    count = ApiKeyStore.active_count(account_id)
    if count >= @max_keys_per_account, do: {:error, :key_limit_reached}, else: :ok
  end

  defp sanitize(key), do: %{key | key_hash: "[REDACTED]"}
  defp generate_secret(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  defp hash_key(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
```
