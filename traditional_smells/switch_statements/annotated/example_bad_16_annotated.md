# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `AccountLifecycle` module — functions `can_login?/1`, `status_banner_message/1`, and `allowed_actions/1`
- **Affected functions:** `can_login?/1`, `status_banner_message/1`, `allowed_actions/1`
- **Short explanation:** The same `case status` branching over `:active`, `:suspended`, `:pending_verification`, and `:deactivated` is duplicated in three functions. Adding a new account status requires updating every case block independently, which is the Switch Statements smell.

---

```elixir
defmodule AccountLifecycle do
  @moduledoc """
  Manages user account lifecycle transitions, status-based access rules,
  and user-facing messaging for the user management system.
  """

  require Logger

  @statuses [:active, :suspended, :pending_verification, :deactivated]

  def valid_statuses, do: @statuses

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over status
  # (:active, :suspended, :pending_verification, :deactivated) is duplicated
  # in can_login?/1, status_banner_message/1, and allowed_actions/1.
  # Adding a new status requires editing all three independently.

  @doc """
  Returns true when the account status permits the user to authenticate.
  """
  def can_login?(%{status: status}) do
    case status do
      :active -> true
      :suspended -> false
      :pending_verification -> false
      :deactivated -> false
      _ -> false
    end
  end

  @doc """
  Returns the informational banner message to display to the user in the UI
  based on their account status. Returns `nil` for active accounts.
  """
  def status_banner_message(%{status: status}) do
    case status do
      :active ->
        nil

      :suspended ->
        "Your account has been suspended. Please contact support to restore access."

      :pending_verification ->
        "Please verify your email address to activate your account."

      :deactivated ->
        "This account has been permanently deactivated."

      _ ->
        "Your account status is unclear. Please contact support."
    end
  end

  @doc """
  Returns the set of actions the user is permitted to perform given their
  current account status.
  """
  def allowed_actions(%{status: status}) do
    case status do
      :active ->
        [:read, :write, :delete, :export, :invite_members]

      :suspended ->
        [:read]

      :pending_verification ->
        [:read, :resend_verification]

      :deactivated ->
        []

      _ ->
        []
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Transitions an account to a new status, recording the reason and actor.
  Returns `{:ok, updated_account}` or `{:error, reason}`.
  """
  def transition(%{status: current_status} = account, new_status, actor_id, reason \\ nil) do
    allowed_transitions = %{
      pending_verification: [:active, :deactivated],
      active: [:suspended, :deactivated],
      suspended: [:active, :deactivated],
      deactivated: []
    }

    allowed = Map.get(allowed_transitions, current_status, [])

    if new_status in allowed do
      updated =
        account
        |> Map.put(:status, new_status)
        |> Map.put(:status_changed_at, DateTime.utc_now())
        |> Map.put(:status_changed_by, actor_id)
        |> Map.put(:status_reason, reason)

      Logger.info("Account #{account.id}: #{current_status} -> #{new_status} by #{actor_id}.")
      {:ok, updated}
    else
      Logger.warning("Blocked invalid account transition: #{current_status} -> #{new_status}.")
      {:error, {:invalid_transition, {current_status, new_status}}}
    end
  end

  @doc """
  Determines whether the given account can perform the requested action.
  """
  def can_perform?(%{} = account, action) do
    action in allowed_actions(account)
  end

  @doc """
  Builds a full account context map used by the session initializer after login.
  """
  def session_context(%{} = account) do
    if can_login?(account) do
      banner = status_banner_message(account)
      actions = allowed_actions(account)

      {:ok,
       %{
         user_id: account.id,
         email: account.email,
         status: account.status,
         banner: banner,
         allowed_actions: actions
       }}
    else
      {:error, {:login_not_permitted, account.status}}
    end
  end

  @doc """
  Sends the appropriate account status email to the user when their status changes.
  """
  def send_status_notification(%{status: new_status} = account) do
    template =
      case new_status do
        :suspended -> "account_suspended"
        :active -> "account_reactivated"
        :pending_verification -> "welcome_verify_email"
        :deactivated -> "account_deactivated"
        _ -> nil
      end

    if template do
      Logger.info("Sending '#{template}' email to #{account.email}.")
      :ok
    else
      :skip
    end
  end
end
```
