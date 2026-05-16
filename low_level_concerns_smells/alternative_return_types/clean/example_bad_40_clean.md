```elixir
defmodule Billing.SubscriptionPlan do
  @moduledoc """
  Retrieves and summarizes subscription plan details for customers.
  Used by API controllers, admin dashboards, and billing jobs.
  """

  alias Billing.Repo
  alias Billing.Schema.{Plan, Subscription, UsageSummary}

  require Logger

  @doc """
  Returns the active subscription plan for a customer.

  ## Options

    * `:include_usage` — When `true`, fetches the current billing period's
      usage summary and returns a `{%Plan{}, %UsageSummary{}}` tuple.
    * `:summarize` — When `true`, returns a lightweight map suitable for
      embedding in API responses:
      `%{name: string, status: atom, next_billing: Date.t(), seats: integer}`.
      Takes precedence over `:include_usage`.

  ## Examples

      iex> for_customer(99)
      %Plan{id: 3, name: "Business", seats: 25, ...}

      iex> for_customer(99, include_usage: true)
      {%Plan{id: 3, ...}, %UsageSummary{api_calls: 14200, storage_gb: 4.2}}

      iex> for_customer(99, summarize: true)
      %{name: "Business", status: :active, next_billing: ~D[2024-07-01], seats: 25}

  """

  def for_customer(customer_id, opts \\ []) when is_list(opts) do
    subscription =
      Subscription
      |> Repo.get_by!(customer_id: customer_id, status: :active)
      |> Repo.preload(:plan)

    plan = subscription.plan

    cond do
      opts[:summarize] == true ->
        %{
          name: plan.name,
          status: subscription.status,
          next_billing: subscription.current_period_end,
          seats: plan.max_seats
        }

      opts[:include_usage] == true ->
        usage = fetch_usage_summary(customer_id, subscription.current_period_start)
        {plan, usage}

      true ->
        plan
    end
  end

  defp fetch_usage_summary(customer_id, period_start) do
    case Repo.get_by(UsageSummary, customer_id: customer_id, period_start: period_start) do
      nil ->
        %UsageSummary{
          customer_id: customer_id,
          api_calls: 0,
          storage_gb: 0.0,
          period_start: period_start
        }

      summary ->
        summary
    end
  end

  @doc """
  Lists all available plans, ordered by price ascending.
  """
  def list_available do
    Plan
    |> Repo.all_by(active: true)
    |> Enum.sort_by(& &1.monthly_price_cents)
  end

  @doc """
  Checks whether a customer has exceeded their seat limit.
  """
  def seats_exceeded?(customer_id) do
    subscription =
      Subscription
      |> Repo.get_by!(customer_id: customer_id, status: :active)
      |> Repo.preload(:plan)

    active_seats = count_active_seats(customer_id)
    active_seats > subscription.plan.max_seats
  end

  defp count_active_seats(customer_id) do
    Repo.count_by(Billing.Schema.Seat, customer_id: customer_id, active: true)
  end

  @doc """
  Upgrades a customer's subscription to the given plan.
  """
  def upgrade(customer_id, new_plan_id) do
    subscription = Repo.get_by!(Subscription, customer_id: customer_id, status: :active)
    new_plan = Repo.get!(Plan, new_plan_id)

    subscription
    |> Subscription.changeset(%{plan_id: new_plan.id})
    |> Repo.update()
  end
end
```
