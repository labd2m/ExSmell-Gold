```elixir
defmodule Audit.EventLogger do
  @moduledoc """
  Records security and compliance audit events for user and
  administrative actions. Events are persisted to a dedicated
  audit store and automatically purged after the configured
  retention period.
  """

  require Logger

  @retention_days Application.fetch_env!(:audit, :retention_days)

  @supported_actions ~w(
    user.login user.logout user.password_change user.mfa_enrolled
    admin.role_assigned admin.role_revoked admin.user_suspended
    billing.subscription_created billing.subscription_cancelled
    data.export_requested data.deletion_requested
  )

  @type actor :: %{id: String.t(), type: :user | :system | :admin}
  @type audit_event :: %{
          id: String.t(),
          action: String.t(),
          actor: actor(),
          target_type: String.t() | nil,
          target_id: String.t() | nil,
          metadata: map(),
          ip_address: String.t() | nil,
          occurred_at: DateTime.t()
        }

  @spec record(String.t(), actor(), keyword()) ::
          {:ok, audit_event()} | {:error, :invalid_action | :store_error}
  def record(action, actor, opts \\ []) when is_binary(action) do
    unless action in @supported_actions do
      Logger.warning("Unsupported audit action", action: action)
      {:error, :invalid_action}
    else
      event = build_event(action, actor, opts)

      case audit_store().insert(event) do
        {:ok, _} ->
          Logger.debug("Audit event recorded", action: action, actor_id: actor.id)
          {:ok, event}

        {:error, reason} ->
          Logger.error("Audit store write failed",
            action: action,
            actor_id: actor.id,
            reason: inspect(reason)
          )

          {:error, :store_error}
      end
    end
  end

  @spec search(keyword()) :: {:ok, [audit_event()]} | {:error, :store_error}
  def search(filters \\ []) do
    query = build_query(filters)

    case audit_store().query(query) do
      {:ok, events} -> {:ok, events}
      {:error, _} -> {:error, :store_error}
    end
  end

  @spec purge_expired() :: {:ok, non_neg_integer()} | {:error, :store_error}
  def purge_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 86_400, :second)

    Logger.info("Purging expired audit events",
      retention_days: @retention_days,
      cutoff: DateTime.to_iso8601(cutoff)
    )

    case audit_store().delete_before(cutoff) do
      {:ok, count} ->
        Logger.info("Audit purge complete", deleted: count)
        {:ok, count}

      {:error, reason} ->
        Logger.error("Audit purge failed", reason: inspect(reason))
        {:error, :store_error}
    end
  end

  @spec retention_policy() :: %{days: integer(), cutoff: DateTime.t()}
  def retention_policy do
    %{
      days: @retention_days,
      cutoff: DateTime.add(DateTime.utc_now(), -@retention_days * 86_400, :second)
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_event(action, actor, opts) do
    %{
      id: generate_id(),
      action: action,
      actor: actor,
      target_type: Keyword.get(opts, :target_type),
      target_id: Keyword.get(opts, :target_id),
      metadata: Keyword.get(opts, :metadata, %{}),
      ip_address: Keyword.get(opts, :ip_address),
      occurred_at: DateTime.utc_now()
    }
  end

  defp build_query(filters) do
    %{
      actor_id: Keyword.get(filters, :actor_id),
      actor_type: Keyword.get(filters, :actor_type),
      action: Keyword.get(filters, :action),
      target_id: Keyword.get(filters, :target_id),
      from: Keyword.get(filters, :from),
      to: Keyword.get(filters, :to),
      limit: Keyword.get(filters, :limit, 100),
      offset: Keyword.get(filters, :offset, 0)
    }
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp audit_store, do: Application.get_env(:audit, :store, Audit.Store)
end
```
