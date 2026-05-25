```elixir
defmodule UserOnboarding do
  @moduledoc """
  Manages the user onboarding flow, including welcome email dispatch
  and post-login routing based on account status for a multi-tenant
  SaaS application.
  """

  alias UserOnboarding.{User, Mailer, EmailTemplate, AuditLog}

  @type user_status ::
          :invited
          | :pending_verification
          | :active
          | :suspended
          | :deactivated

  @spec handle_login(User.t()) ::
          {:redirect, String.t()} | {:error, :access_denied}
  def handle_login(%User{} = user) do
    case user.status do
      :active -> {:redirect, landing_path(user)}
      :suspended -> {:error, :access_denied}
      :deactivated -> {:error, :access_denied}
      _ -> {:redirect, landing_path(user)}
    end
  end

  @spec send_welcome_communication(User.t()) :: :ok | {:error, term()}
  def send_welcome_communication(%User{} = user) do
    template_name = welcome_template(user.status)

    case EmailTemplate.load(template_name) do
      {:ok, template} ->
        Mailer.deliver(to: user.email, template: template, assigns: %{user: user})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec onboarding_summary(User.t()) :: map()
  def onboarding_summary(%User{} = user) do
    %{
      user_id: user.id,
      email: user.email,
      status: user.status,
      landing_path: landing_path(user),
      welcome_template: welcome_template(user.status),
      onboarding_complete: user.status == :active
    }
  end

  @spec welcome_template(user_status()) :: String.t()
  def welcome_template(status) do
    case status do
      :invited              -> "welcome_invite"
      :pending_verification -> "welcome_verify_email"
      :active               -> "welcome_active"
      :suspended            -> "account_suspended"
      :deactivated          -> "account_deactivated"
    end
  end

  @spec landing_path(User.t()) :: String.t()
  def landing_path(%User{status: status}) do
    case status do
      :invited              -> "/accept-invitation"
      :pending_verification -> "/verify-email"
      :active               -> "/dashboard"
      :suspended            -> "/account/suspended"
      :deactivated          -> "/account/deactivated"
    end
  end

  @spec resend_invite(User.t()) :: :ok | {:error, String.t()}
  def resend_invite(%User{status: :invited} = user) do
    AuditLog.record(:invite_resent, user.id)
    send_welcome_communication(user)
  end

  def resend_invite(%User{status: status}) do
    {:error, "cannot resend invite for user with status #{status}"}
  end

  @spec mark_verified(User.t()) :: {:ok, User.t()} | {:error, String.t()}
  def mark_verified(%User{status: :pending_verification} = user) do
    updated = %{user | status: :active, email_verified_at: DateTime.utc_now()}
    AuditLog.record(:email_verified, user.id)
    {:ok, updated}
  end

  def mark_verified(%User{status: status}) do
    {:error, "expected :pending_verification status, got :#{status}"}
  end
end
```
