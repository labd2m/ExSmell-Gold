# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `UserManagement.AccountDeactivator.deactivate/3`
- **Affected function(s):** `deactivate/3`
- **Short explanation:** The `deactivate/3` function performs permission checking, active subscription cancellation, open order validation, session revocation, API key expiry, data anonymisation, deactivation record persistence, a farewell email, and audit logging — all inside one function. Each of those is a clearly separate concern that deserves its own private helper.

---

```elixir
defmodule UserManagement.AccountDeactivator do
  @moduledoc """
  Handles full account deactivation, coordinating subscription cancellation,
  session cleanup, data anonymisation, and compliance audit records.
  """

  alias UserManagement.{User, ApiKey, AuditEntry, Repo}
  alias Auth.Session
  alias Billing.{Subscription, SubscriptionCanceller}
  alias Orders.Order
  alias Integrations.Mailer
  require Logger

  @anonymise_fields [:phone, :bio, :avatar_url]
  @deactivation_reasons [:user_request, :admin_action, :inactivity, :policy_violation]

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `deactivate/3` combines authorization,
  # VALIDATION: subscription cancellation, open-order blocking, session revocation,
  # VALIDATION: API key expiry, PII anonymisation, deactivation persistence,
  # VALIDATION: farewell email, and audit logging all in one very long function.
  def deactivate(actor_id, target_user_id, reason)
      when reason in @deactivation_reasons do
    Logger.info("Deactivating user=#{target_user_id} by actor=#{actor_id} reason=#{reason}")

    actor = Repo.get!(User, actor_id)

    # --- Authorisation ---
    unless actor_id == target_user_id or actor.role in [:admin, :support] do
      {:error, :unauthorised}
    else
      case Repo.get(User, target_user_id) do
        nil ->
          {:error, :user_not_found}

        %User{status: :deactivated} ->
          {:error, :already_deactivated}

        %User{} = user ->
          # --- Block deactivation if open orders exist ---
          open_order_count =
            Order
            |> Order.for_user(target_user_id)
            |> Order.in_statuses([:paid, :processing, :in_fulfillment])
            |> Repo.aggregate(:count, :id)

          if open_order_count > 0 do
            Logger.warning("Deactivation blocked for user #{target_user_id}: #{open_order_count} open order(s)")
            {:error, {:open_orders_exist, open_order_count}}
          else
            # --- Cancel active subscriptions ---
            active_subs =
              Subscription
              |> Subscription.for_user(target_user_id)
              |> Subscription.active()
              |> Repo.all()

            Enum.each(active_subs, fn sub ->
              case SubscriptionCanceller.cancel(sub.id, :account_deactivated) do
                {:ok, _}       -> Logger.info("Subscription #{sub.id} cancelled for deactivated user #{target_user_id}")
                {:error, err}  -> Logger.warning("Could not cancel subscription #{sub.id}: #{inspect(err)}")
              end
            end)

            # --- Revoke all sessions ---
            sessions =
              Session
              |> Session.for_user(target_user_id)
              |> Session.active()
              |> Repo.all()

            revoked_session_count = length(sessions)

            Enum.each(sessions, fn s ->
              s |> Session.changeset(%{revoked: true, revoked_reason: :account_deactivated}) |> Repo.update!()
            end)

            # --- Expire all API keys ---
            api_keys =
              ApiKey
              |> ApiKey.for_user(target_user_id)
              |> ApiKey.active()
              |> Repo.all()

            Enum.each(api_keys, fn key ->
              key |> ApiKey.changeset(%{status: :revoked, revoked_at: DateTime.utc_now()}) |> Repo.update!()
            end)

            # --- Anonymise PII fields ---
            anon_attrs =
              Enum.reduce(@anonymise_fields, %{}, fn field, acc ->
                Map.put(acc, field, nil)
              end)
              |> Map.merge(%{
                full_name: "Deleted User",
                username: "deleted_#{target_user_id}",
                status: :deactivated,
                deactivated_at: DateTime.utc_now(),
                deactivation_reason: reason
              })

            {:ok, deactivated_user} =
              user
              |> User.changeset(anon_attrs)
              |> Repo.update()

            # --- Send farewell email (only for voluntary deactivation) ---
            if reason == :user_request do
              Mailer.send_account_deactivated(%{
                to: user.email,
                full_name: user.full_name
              })
            end

            # --- Audit entry ---
            Repo.insert!(%AuditEntry{
              user_id: target_user_id,
              actor_id: actor_id,
              action: "account_deactivated",
              metadata: %{
                reason: reason,
                sessions_revoked: revoked_session_count,
                subscriptions_cancelled: length(active_subs),
                api_keys_expired: length(api_keys)
              },
              occurred_at: DateTime.utc_now()
            })

            Logger.info("User #{target_user_id} deactivated successfully")
            {:ok, deactivated_user}
          end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
