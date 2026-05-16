```elixir
defmodule ApiGateway.KeyProvisioner do
  alias ApiGateway.{Repo, Account, ApiKey, QuotaManager, ScopeValidator, AuditLogger}

  require Logger

  @max_keys_per_account 10
  @key_prefix "sk"

  def provision_api_key(account_id, requested_scopes, label) do
    with {:ok, account} <- fetch_active_account(account_id),
         :ok <- QuotaManager.check_key_quota(account, @max_keys_per_account),
         {:ok, scopes} <- ScopeValidator.validate(requested_scopes, account.plan),
         {:ok, raw_key, hashed_key} <- generate_key(),
         {:ok, api_key} <- persist_api_key(account, scopes, hashed_key, label),
         :ok <- AuditLogger.log(:api_key_created, %{account_id: account_id, key_id: api_key.id}) do
      Logger.info("API key #{api_key.id} provisioned for account #{account_id}")

      {:ok, %{
        key_id: api_key.id,
        raw_key: "#{@key_prefix}_#{raw_key}",
        scopes: scopes,
        label: label
      }}
    else
      {:error, :not_found} ->
        Logger.warning("Account #{account_id} not found during key provisioning")
        {:error, :account_not_found}

      {:error, :suspended} ->
        Logger.warning("Key provisioning blocked — account #{account_id} is suspended")
        {:error, :account_suspended}

      {:error, :quota_exceeded} ->
        Logger.warning("Account #{account_id} has reached max API key limit")
        {:error, :key_quota_exceeded}

      {:error, {:invalid_scopes, unknown}} ->
        Logger.warning("Unknown scopes requested: #{inspect(unknown)}")
        {:error, {:invalid_scopes, unknown}}

      {:error, :plan_does_not_support_scopes} ->
        Logger.warning("Account #{account_id} plan does not support requested scopes")
        {:error, :insufficient_plan}

      {:error, :key_generation_error} ->
        Logger.error("Key generation failed for account #{account_id}")
        {:error, :internal_error}

      {:error, :db_error} ->
        Logger.error("Failed to persist API key for account #{account_id}")
        {:error, :persistence_failed}

      {:error, :audit_failed} ->
        Logger.warning("Audit log write failed for API key provisioning on account #{account_id}")
        {:error, :audit_error}
    end
  end

  defp fetch_active_account(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      %Account{status: :suspended} -> {:error, :suspended}
      account -> {:ok, account}
    end
  end

  defp generate_key do
    try do
      raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      hashed = :crypto.hash(:sha256, raw) |> Base.hex_encode32(case: :lower)
      {:ok, raw, hashed}
    rescue
      _ -> {:error, :key_generation_error}
    end
  end

  defp persist_api_key(account, scopes, hashed_key, label) do
    %ApiKey{}
    |> ApiKey.changeset(%{
      account_id: account.id,
      hashed_key: hashed_key,
      scopes: scopes,
      label: label,
      status: :active
    })
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, key}
      {:error, _} -> {:error, :db_error}
    end
  end
end
```
