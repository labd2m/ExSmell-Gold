```elixir
defmodule Subscription.Plan do
  @moduledoc """
  Defines the available subscription plans and their feature entitlements.
  Plan data is static and compiled into the module — changes require redeployment.
  """

  @type feature ::
          :api_access
          | :custom_domain
          | :analytics
          | :priority_support
          | :sso
          | :audit_log

  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          price_cents_monthly: non_neg_integer(),
          max_seats: pos_integer() | :unlimited,
          features: list(feature())
        }

  @enforce_keys [:key, :label, :price_cents_monthly, :max_seats, :features]
  defstruct [:key, :label, :price_cents_monthly, :max_seats, :features]

  @plans %{
    free: %__MODULE__{
      key: :free,
      label: "Free",
      price_cents_monthly: 0,
      max_seats: 3,
      features: [:api_access]
    },
    starter: %__MODULE__{
      key: :starter,
      label: "Starter",
      price_cents_monthly: 2_900,
      max_seats: 10,
      features: [:api_access, :analytics, :custom_domain]
    },
    business: %__MODULE__{
      key: :business,
      label: "Business",
      price_cents_monthly: 9_900,
      max_seats: 50,
      features: [:api_access, :analytics, :custom_domain, :priority_support, :audit_log]
    },
    enterprise: %__MODULE__{
      key: :enterprise,
      label: "Enterprise",
      price_cents_monthly: 29_900,
      max_seats: :unlimited,
      features: [:api_access, :analytics, :custom_domain, :priority_support, :audit_log, :sso]
    }
  }

  @spec get(atom()) :: {:ok, t()} | {:error, :unknown_plan}
  def get(key) when is_atom(key) do
    case Map.fetch(@plans, key) do
      {:ok, plan} -> {:ok, plan}
      :error -> {:error, :unknown_plan}
    end
  end

  @spec all() :: list(t())
  def all, do: Map.values(@plans)

  @spec includes_feature?(t(), feature()) :: boolean()
  def includes_feature?(%__MODULE__{features: features}, feature) when is_atom(feature) do
    feature in features
  end

  @spec seats_available?(t(), non_neg_integer()) :: boolean()
  def seats_available?(%__MODULE__{max_seats: :unlimited}, _current_seats), do: true

  def seats_available?(%__MODULE__{max_seats: max}, current_seats)
      when is_integer(current_seats) and current_seats >= 0 do
    current_seats < max
  end

  @spec upgrades_to?(t(), t()) :: boolean()
  def upgrades_to?(%__MODULE__{price_cents_monthly: from}, %__MODULE__{price_cents_monthly: to}) do
    to > from
  end
end

defmodule Subscription.Entitlement do
  @moduledoc """
  Checks feature entitlements for an active subscription,
  given the tenant's current plan and seat count.
  """

  alias Subscription.Plan

  @type subscription :: %{plan_key: atom(), seat_count: non_neg_integer()}

  @spec feature_allowed?(subscription(), Plan.feature()) ::
          {:ok, :allowed} | {:error, :plan_restriction} | {:error, :unknown_plan}
  def feature_allowed?(%{plan_key: key}, feature) when is_atom(feature) do
    with {:ok, plan} <- Plan.get(key) do
      if Plan.includes_feature?(plan, feature) do
        {:ok, :allowed}
      else
        {:error, :plan_restriction}
      end
    end
  end

  @spec can_add_seat?(subscription()) ::
          {:ok, :allowed} | {:error, :seat_limit_reached} | {:error, :unknown_plan}
  def can_add_seat?(%{plan_key: key, seat_count: seats}) do
    with {:ok, plan} <- Plan.get(key) do
      if Plan.seats_available?(plan, seats) do
        {:ok, :allowed}
      else
        {:error, :seat_limit_reached}
      end
    end
  end

  @spec required_plan_for(Plan.feature()) :: list(atom())
  def required_plan_for(feature) when is_atom(feature) do
    Plan.all()
    |> Enum.filter(&Plan.includes_feature?(&1, feature))
    |> Enum.map(& &1.key)
  end
end
```
