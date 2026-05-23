# Annotated Example 04: Feature Envy

## Metadata

- **Smell**: Feature Envy
- **Expected Smell Location**: `Notifications.EmailComposer.compose_subscription_details/1`
- **Affected Function(s)**: `compose_subscription_details/1`
- **Explanation**: `compose_subscription_details/1` exclusively uses functions and data
  from the `Subscription` module (`Subscription.plan_name/1`, `Subscription.renewal_date/1`,
  `Subscription.amount_due/1`, `Subscription.payment_method_summary/1`,
  `Subscription.billing_cycle/1`, `Subscription.grace_period_days/1`, and struct fields).
  `EmailComposer` contributes no logic of its own here; the function is entirely oriented
  toward `Subscription` data and behavior.

## Code

```elixir
defmodule Notifications.EmailComposer do
  alias Notifications.{Template, Mailer}
  alias Billing.Subscription

  @doc """
  Sends a renewal reminder email to the subscription holder ahead of the next billing date.
  """
  def send_renewal_reminder(subscription_id) do
    subscription = Subscription.get!(subscription_id)
    details = compose_subscription_details(subscription)

    Mailer.deliver(%{
      to: subscription.email,
      subject: "Your subscription renews soon – #{details.plan}",
      html_body: Template.render("renewal_reminder.html", details),
      text_body: Template.render("renewal_reminder.txt", details)
    })
  end

  @doc """
  Sends a payment failure notification to the subscription holder.
  """
  def send_payment_failure(subscription_id, failure_code) do
    subscription = Subscription.get!(subscription_id)
    details = compose_subscription_details(subscription)
    failure_message = payment_failure_message(failure_code)

    Mailer.deliver(%{
      to: subscription.email,
      subject: "Action required: Payment failed for #{details.plan}",
      html_body:
        Template.render("payment_failure.html", Map.put(details, :failure_message, failure_message)),
      text_body:
        Template.render("payment_failure.txt", Map.put(details, :failure_message, failure_message))
    })
  end

  @doc """
  Sends a cancellation confirmation email when a subscription is terminated.
  """
  def send_cancellation_confirmation(subscription_id) do
    subscription = Subscription.get!(subscription_id)

    Mailer.deliver(%{
      to: subscription.email,
      subject: "Your subscription has been cancelled",
      html_body:
        Template.render("cancellation.html", %{
          holder_name: subscription.holder_name,
          plan: Subscription.plan_name(subscription),
          ends_at: Subscription.current_period_end(subscription)
        }),
      text_body:
        Template.render("cancellation.txt", %{
          holder_name: subscription.holder_name,
          plan: Subscription.plan_name(subscription)
        })
    })
  end

  @doc """
  Sends an upgrade confirmation email after a plan change.
  """
  def send_upgrade_confirmation(subscription_id, previous_plan_name) do
    subscription = Subscription.get!(subscription_id)

    Mailer.deliver(%{
      to: subscription.email,
      subject: "You've upgraded your plan",
      html_body:
        Template.render("upgrade_confirmation.html", %{
          holder_name: subscription.holder_name,
          previous_plan: previous_plan_name,
          new_plan: Subscription.plan_name(subscription)
        })
    })
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because compose_subscription_details/1 exclusively uses
  # VALIDATION: functions and data from the Subscription module: Subscription.plan_name/1,
  # VALIDATION: Subscription.renewal_date/1, Subscription.amount_due/1,
  # VALIDATION: Subscription.payment_method_summary/1, Subscription.billing_cycle/1,
  # VALIDATION: Subscription.grace_period_days/1, and subscription struct fields.
  # VALIDATION: EmailComposer contributes no logic of its own here; the function is entirely
  # VALIDATION: oriented toward Subscription data and behavior.
  defp compose_subscription_details(subscription) do
    plan_name = Subscription.plan_name(subscription)
    renewal_date = Subscription.renewal_date(subscription)
    amount_due = Subscription.amount_due(subscription)
    payment_method = Subscription.payment_method_summary(subscription)
    billing_cycle = Subscription.billing_cycle(subscription)
    grace_days = Subscription.grace_period_days(subscription)

    %{
      holder_name: subscription.holder_name,
      email: subscription.email,
      plan: plan_name,
      renewal_date: Calendar.strftime(renewal_date, "%B %d, %Y"),
      amount_due: amount_due,
      currency: subscription.currency,
      payment_method: payment_method,
      billing_cycle: billing_cycle,
      grace_period_days: grace_days
    }
  end
  # VALIDATION: SMELL END

  defp payment_failure_message(:insufficient_funds), do: "Your card has insufficient funds."
  defp payment_failure_message(:card_expired), do: "Your card has expired."
  defp payment_failure_message(:card_declined), do: "Your card was declined by your bank."
  defp payment_failure_message(_), do: "An unexpected error occurred with your payment method."
end
```
