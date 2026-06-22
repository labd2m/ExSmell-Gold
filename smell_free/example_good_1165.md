**File:** `example_good_1165.md`

```elixir
defmodule Billing.Plan do
  @moduledoc "Represents a subscription plan with pricing and interval configuration."

  @enforce_keys [:id, :name, :amount_cents, :currency, :interval]
  defstruct [:id, :name, :amount_cents, :currency, :interval, :trial_days]

  @type interval :: :monthly | :yearly
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          interval: interval(),
          trial_days: non_neg_integer() | nil
        }
end

defmodule Billing.Subscription do
  @moduledoc "Schema for a customer subscription record."

  use Ecto.Schema
  import Ecto.Changeset

  alias Billing.Plan

  @type status :: :trialing | :active | :past_due | :cancelled
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          customer_id: String.t(),
          plan_id: String.t(),
          status: status(),
          current_period_start: DateTime.t(),
          current_period_end: DateTime.t(),
          cancelled_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "subscriptions" do
    field :customer_id, :string
    field :plan_id, :string
    field :status, Ecto.Enum, values: [:trialing, :active, :past_due, :cancelled]
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    timestamps()
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(sub, attrs) do
    sub
    |> cast(attrs, [:customer_id, :plan_id, :status, :current_period_start, :current_period_end])
    |> validate_required([:customer_id, :plan_id, :status, :current_period_start, :current_period_end])
    |> unique_constraint([:customer_id, :plan_id])
  end

  @spec cancel_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def cancel_changeset(sub, cancelled_at) do
    sub
    |> change(status: :cancelled, cancelled_at: cancelled_at)
  end
end

defmodule Billing.Proration do
  @moduledoc """
  Calculates prorated credit and charge amounts when a subscription
  plan changes mid-billing-period.
  """

  alias Billing.{Plan, Subscription}

  @type proration_result :: %{
          credit_cents: non_neg_integer(),
          charge_cents: non_neg_integer(),
          net_cents: integer()
        }

  @spec calculate(Subscription.t(), Plan.t(), Plan.t(), DateTime.t()) :: proration_result()
  def calculate(%Subscription{} = sub, %Plan{} = old_plan, %Plan{} = new_plan, %DateTime{} = at) do
    remaining_days = days_remaining(sub.current_period_end, at)
    total_days = days_in_period(sub.current_period_start, sub.current_period_end)

    credit_cents = prorate(old_plan.amount_cents, remaining_days, total_days)
    charge_cents = prorate(new_plan.amount_cents, remaining_days, total_days)

    %{
      credit_cents: credit_cents,
      charge_cents: charge_cents,
      net_cents: charge_cents - credit_cents
    }
  end

  defp days_remaining(%DateTime{} = period_end, %DateTime{} = now) do
    diff = DateTime.diff(period_end, now, :second)
    max(0, ceil(diff / 86_400))
  end

  defp days_in_period(%DateTime{} = start, %DateTime{} = finish) do
    diff = DateTime.diff(finish, start, :second)
    max(1, ceil(diff / 86_400))
  end

  defp prorate(amount_cents, remaining_days, total_days) do
    round(amount_cents * remaining_days / total_days)
  end
end

defmodule Billing.Subscriptions do
  @moduledoc """
  Context for managing customer subscriptions and plan transitions.
  """

  alias Billing.{Plan, Proration, Subscription}
  alias MyApp.Repo

  @spec create(String.t(), Plan.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def create(customer_id, %Plan{} = plan) do
    now = DateTime.utc_now()
    period_end = advance_period(now, plan.interval)

    attrs = %{
      customer_id: customer_id,
      plan_id: plan.id,
      status: if(plan.trial_days, do: :trialing, else: :active),
      current_period_start: now,
      current_period_end: if(plan.trial_days, do: DateTime.add(now, plan.trial_days, :day), else: period_end)
    }

    %Subscription{}
    |> Subscription.creation_changeset(attrs)
    |> Repo.insert()
  end

  @spec cancel(Subscription.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def cancel(%Subscription{status: :cancelled}), do: {:error, :already_cancelled}
  def cancel(%Subscription{} = sub) do
    sub
    |> Subscription.cancel_changeset(DateTime.utc_now())
    |> Repo.update()
  end

  @spec change_plan(Subscription.t(), Plan.t(), Plan.t()) ::
          {:ok, Subscription.t(), Proration.proration_result()} | {:error, Ecto.Changeset.t()}
  def change_plan(%Subscription{} = sub, %Plan{} = old_plan, %Plan{} = new_plan) do
    now = DateTime.utc_now()
    proration = Proration.calculate(sub, old_plan, new_plan, now)

    result =
      sub
      |> Ecto.Changeset.change(plan_id: new_plan.id)
      |> Repo.update()

    case result do
      {:ok, updated} -> {:ok, updated, proration}
      {:error, _} = err -> err
    end
  end

  defp advance_period(from, :monthly), do: DateTime.add(from, 30, :day)
  defp advance_period(from, :yearly), do: DateTime.add(from, 365, :day)
end
```
