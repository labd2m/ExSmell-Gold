```elixir
defmodule Platform.StorageQuotaContext do
  @moduledoc """
  Enforces per-account storage quotas. Before accepting a file upload the
  caller asks the quota context whether sufficient space is available. On
  completion the stored bytes are recorded. Quota definitions are linked to
  subscription plans and can be overridden per account for enterprise
  arrangements. All state is persisted in the database for durability.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Platform.{StorageUsage, AccountQuota}

  @type account_id :: String.t()
  @type bytes :: non_neg_integer()

  @doc """
  Returns `{:ok, :available}` when `bytes_needed` fits within the account's
  remaining quota, or `{:error, :quota_exceeded}` when it does not.
  """
  @spec check(account_id(), bytes()) ::
          {:ok, :available} | {:error, :quota_exceeded | :quota_not_configured}
  def check(account_id, bytes_needed)
      when is_binary(account_id) and is_integer(bytes_needed) and bytes_needed >= 0 do
    with {:ok, limit} <- fetch_limit(account_id) do
      used = current_usage(account_id)
      if used + bytes_needed <= limit do
        {:ok, :available}
      else
        {:error, :quota_exceeded}
      end
    end
  end

  @doc "Records `bytes` as consumed storage for `account_id`."
  @spec record_usage(account_id(), bytes(), String.t()) ::
          {:ok, StorageUsage.t()} | {:error, Ecto.Changeset.t()}
  def record_usage(account_id, bytes, object_key)
      when is_binary(account_id) and is_integer(bytes) and bytes > 0 and is_binary(object_key) do
    attrs = %{account_id: account_id, bytes: bytes, object_key: object_key}
    %StorageUsage{} |> StorageUsage.changeset(attrs) |> Repo.insert()
  end

  @doc "Removes the usage record for `object_key` when a file is deleted."
  @spec release_usage(String.t()) :: :ok
  def release_usage(object_key) when is_binary(object_key) do
    Repo.delete_all(from(u in StorageUsage, where: u.object_key == ^object_key))
    :ok
  end

  @doc "Returns the total bytes stored for `account_id`."
  @spec current_usage(account_id()) :: bytes()
  def current_usage(account_id) when is_binary(account_id) do
    from(u in StorageUsage,
      where: u.account_id == ^account_id,
      select: sum(u.bytes)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the quota limit in bytes for `account_id`."
  @spec fetch_limit(account_id()) :: {:ok, bytes()} | {:error, :quota_not_configured}
  def fetch_limit(account_id) when is_binary(account_id) do
    case Repo.get_by(AccountQuota, account_id: account_id) do
      nil -> {:error, :quota_not_configured}
      %AccountQuota{limit_bytes: limit} -> {:ok, limit}
    end
  end

  @doc "Sets or updates the quota limit for `account_id`."
  @spec set_limit(account_id(), bytes()) ::
          {:ok, AccountQuota.t()} | {:error, Ecto.Changeset.t()}
  def set_limit(account_id, limit_bytes)
      when is_binary(account_id) and is_integer(limit_bytes) and limit_bytes > 0 do
    existing = Repo.get_by(AccountQuota, account_id: account_id) || %AccountQuota{account_id: account_id}

    existing
    |> AccountQuota.changeset(%{limit_bytes: limit_bytes})
    |> Repo.insert_or_update()
  end

  @doc "Returns usage as a percentage of the limit, or nil when quota is unconfigured."
  @spec usage_percent(account_id()) :: float() | nil
  def usage_percent(account_id) when is_binary(account_id) do
    case fetch_limit(account_id) do
      {:error, :quota_not_configured} ->
        nil

      {:ok, limit} ->
        used = current_usage(account_id)
        if limit > 0, do: Float.round(used / limit * 100, 2), else: 0.0
    end
  end
end
```
