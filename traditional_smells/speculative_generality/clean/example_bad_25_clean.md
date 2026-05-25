```elixir
defmodule UserManagement.AccountSuspender do
  @moduledoc """
  Handles account suspension lifecycle: applying suspensions, recording audit
  events, and notifying affected users and internal compliance teams.

  Suspensions are reversible. A suspended account cannot log in or perform
  any authenticated operations until the suspension is lifted.
  """

  require Logger

  alias UserManagement.{Account, AuditLog, NotificationService, ComplianceAlert}

  @suspension_reasons [
    :policy_violation,
    :payment_failure,
    :fraud_investigation,
    :duplicate_account,
    :user_request
  ]

  @spec suspend(String.t(), atom()) ::
          {:ok, Account.t()} | {:error, atom()}
  def suspend(account_id, reason, notify_user \\ true) do
    with :ok <- validate_reason(reason),
         {:ok, account} <- Account.fetch(account_id),
         :ok <- ensure_not_already_suspended(account),
         {:ok, suspended_account} <- Account.apply_suspension(account, reason),
         :ok <- AuditLog.record(:suspension_applied, account_id, %{reason: reason}),
         :ok <- ComplianceAlert.notify_team(suspended_account, reason) do
      if notify_user do
        case NotificationService.send_suspension_notice(suspended_account) do
          :ok ->
            Logger.info("Suspension notice sent for account=#{account_id}")

          {:error, notif_err} ->
            Logger.warning("Failed to send suspension notice account=#{account_id}: #{inspect(notif_err)}")
        end
      end

      Logger.info("Account suspended id=#{account_id} reason=#{reason}")
      {:ok, suspended_account}
    else
      {:error, :not_found} ->
        Logger.warning("Suspend failed: account not found id=#{account_id}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Suspend failed for account=#{account_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec lift(String.t(), String.t()) :: {:ok, Account.t()} | {:error, atom()}
  def lift(account_id, lifted_by) do
    with {:ok, account} <- Account.fetch(account_id),
         :ok <- ensure_is_suspended(account),
         {:ok, reinstated} <- Account.lift_suspension(account),
         :ok <- AuditLog.record(:suspension_lifted, account_id, %{lifted_by: lifted_by}),
         :ok <- NotificationService.send_reinstatement_notice(reinstated) do
      Logger.info("Suspension lifted for account=#{account_id} by=#{lifted_by}")
      {:ok, reinstated}
    end
  end

  defp validate_reason(reason) when reason in @suspension_reasons, do: :ok
  defp validate_reason(reason), do: {:error, {:invalid_reason, reason}}

  defp ensure_not_already_suspended(%Account{status: :suspended}),
    do: {:error, :already_suspended}

  defp ensure_not_already_suspended(_account), do: :ok

  defp ensure_is_suspended(%Account{status: :suspended}), do: :ok
  defp ensure_is_suspended(_account), do: {:error, :not_suspended}
end

defmodule UserManagement.PolicyEnforcer do
  alias UserManagement.AccountSuspender

  def enforce_payment_failure(account_id) do
    AccountSuspender.suspend(account_id, :payment_failure)
  end

  def enforce_policy_violation(account_id) do
    AccountSuspender.suspend(account_id, :policy_violation)
  end

  def enforce_duplicate_account(account_id) do
    AccountSuspender.suspend(account_id, :duplicate_account)
  end
end
```
