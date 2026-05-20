# Annotated Example — Smell: Unrelated multi-clause function

## Metadata

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `UserLifecycleManager.transition/1`
- **Affected function(s):** `transition/1`
- **Short explanation:** The `transition/1` function clusters three unrelated user lifecycle operations — onboarding a new user, suspending an existing user, and anonymising a deleted user's data for GDPR compliance — under one multi-clause function. Each clause involves different workflows, different legal obligations, different external integrations, and different domain events. They are not lifecycle "transitions" in any unified sense, and conflating them makes the code significantly harder to understand, document, and modify safely.

---

```elixir
defmodule MyApp.UserLifecycleManager do
  @moduledoc """
  Manages key transitions in the user lifecycle including onboarding,
  suspension, and data anonymisation for compliance.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Accounts.{User, UserProfile, UserAuditLog}
  alias MyApp.Integrations.{SegmentClient, IntercomClient, SlackNotifier}
  alias MyApp.Compliance.GdprAnonymiser
  alias MyApp.Notifications.Mailer
  alias MyApp.Auth.SessionStore

  @trial_period_days 14

  @doc """
  Applies a lifecycle transition to a user record.

  Accepts one of:
  - `%{action: :onboard, user_id: id, plan: plan}`
  - `%{action: :suspend, user_id: id, reason: reason, actor_id: admin_id}`
  - `%{action: :anonymise, user_id: id, requested_by: email}`

  ## Examples

      iex> MyApp.UserLifecycleManager.transition(%{action: :onboard, user_id: 42, plan: :trial})
      {:ok, %User{status: :active}}

  """

  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because the three clauses handle fundamentally
  # unrelated user lifecycle events: account setup and welcome flow, enforcement
  # of an administrative suspension, and GDPR-required data anonymisation.
  # These represent distinct workflows with different stakeholders, obligations,
  # integrations, and consequences. They should be separate named functions.

  def transition(%{action: :onboard, user_id: user_id, plan: plan}) do
    Logger.info("Onboarding user #{user_id} on plan #{plan}")

    user = Repo.get!(User, user_id)

    trial_ends_at =
      if plan == :trial,
        do: DateTime.add(DateTime.utc_now(), @trial_period_days * 86_400, :second),
        else: nil

    {:ok, updated_user} =
      Repo.update(
        User.changeset(user, %{
          status: :active,
          plan: plan,
          trial_ends_at: trial_ends_at,
          onboarded_at: DateTime.utc_now()
        })
      )

    {:ok, _profile} =
      Repo.insert(
        UserProfile.changeset(%UserProfile{}, %{
          user_id: user_id,
          preferences: %{},
          notification_settings: default_notification_settings()
        })
      )

    SegmentClient.track(user_id, "User Onboarded", %{plan: plan})
    IntercomClient.create_or_update_user(user_id, %{plan: plan, status: "active"})
    Mailer.send_welcome_email(updated_user)

    UserAuditLog.record!(user_id, :onboarded, %{plan: plan})
    Logger.info("User #{user_id} successfully onboarded on #{plan}")
    {:ok, updated_user}
  end

  def transition(%{action: :suspend, user_id: user_id, reason: reason, actor_id: actor_id}) do
    Logger.info("Suspending user #{user_id} for reason: #{reason} (actor: #{actor_id})")

    user = Repo.get!(User, user_id)

    if user.status == :suspended do
      Logger.warn("User #{user_id} is already suspended")
      {:error, :already_suspended}
    else
      {:ok, updated_user} =
        Repo.update(
          User.changeset(user, %{
            status: :suspended,
            suspended_at: DateTime.utc_now(),
            suspension_reason: reason
          })
        )

      SessionStore.revoke_all_for_user(user_id)
      SegmentClient.track(user_id, "User Suspended", %{reason: reason})
      IntercomClient.tag_user(user_id, "suspended")

      SlackNotifier.post(
        "#trust-and-safety",
        "User #{user_id} (#{user.email}) suspended by admin #{actor_id}. Reason: #{reason}"
      )

      Mailer.send_suspension_notice(updated_user, reason)
      UserAuditLog.record!(user_id, :suspended, %{reason: reason, actor_id: actor_id})

      Logger.info("User #{user_id} suspended successfully")
      {:ok, updated_user}
    end
  end

  def transition(%{action: :anonymise, user_id: user_id, requested_by: requested_by}) do
    Logger.info("GDPR anonymisation initiated for user #{user_id} by #{requested_by}")

    user = Repo.get!(User, user_id)

    if user.status not in [:deleted, :suspended] do
      Logger.warn("Anonymisation requested for non-deleted user #{user_id}, blocking")
      {:error, :user_must_be_deleted_first}
    else
      anonymised_email = "anon_#{user_id}@deleted.myapp.io"

      with {:ok, _} <- GdprAnonymiser.anonymise_pii(user_id),
           {:ok, anonymised_user} <-
             Repo.update(
               User.changeset(user, %{
                 email: anonymised_email,
                 name: "Deleted User",
                 status: :anonymised,
                 anonymised_at: DateTime.utc_now()
               })
             ) do
        Repo.delete_all(from p in UserProfile, where: p.user_id == ^user_id)
        IntercomClient.delete_user(user_id)
        SegmentClient.delete_user(user_id)

        UserAuditLog.record!(user_id, :anonymised, %{requested_by: requested_by})
        Logger.info("GDPR anonymisation complete for user #{user_id}")
        {:ok, anonymised_user}
      end
    end
  end

  # VALIDATION: SMELL END

  defp default_notification_settings do
    %{
      email_marketing: false,
      email_transactional: true,
      in_app_alerts: true,
      sms_two_factor: false
    }
  end
end
```
