```elixir
defmodule Billing.Subscriptions.PlanCatalog do
  @moduledoc """
  Defines and validates available subscription plans. Plans are modeled
  as structs with typed fields rather than bare primitives, enabling
  reliable pattern matching throughout the billing domain.
  """

  alias Billing.Subscriptions.Plan

  @plans %{
    starter: %Plan{
      id: :starter,
      name: "Starter",
      monthly_price_cents: 900,
      annual_price_cents: 8_640,
      max_seats: 3,
      features: [:basic_analytics, :api_access]
    },
    growth: %Plan{
      id: :growth,
      name: "Growth",
      monthly_price_cents: 2_900,
      annual_price_cents: 27_840,
      max_seats: 15,
      features: [:basic_analytics, :advanced_analytics, :api_access, :priority_support]
    },
    enterprise: %Plan{
      id: :enterprise,
      name: "Enterprise",
      monthly_price_cents: 9_900,
      annual_price_cents: 95_040,
      max_seats: :unlimited,
      features: [:basic_analytics, :advanced_analytics, :api_access, :priority_support, :sso, :audit_log]
    }
  }

  @type billing_cycle :: :monthly | :annual
  @type plan_id :: :starter | :growth | :enterprise

  @doc "Returns all available plans."
  @spec all() :: [Plan.t()]
  def all, do: Map.values(@plans)

  @doc "Fetches a plan by its ID. Returns `{:error, :not_found}` for unknown plans."
  @spec fetch(plan_id()) :: {:ok, Plan.t()} | {:error, :not_found}
  def fetch(plan_id) when is_atom(plan_id) do
    case Map.fetch(@plans, plan_id) do
      {:ok, plan} -> {:ok, plan}
      :error -> {:error, :not_found}
    end
  end

  @doc "Calculates the price for a plan and billing cycle."
  @spec price_for(Plan.t(), billing_cycle()) :: {:ok, pos_integer()} | {:error, :invalid_cycle}
  def price_for(%Plan{monthly_price_cents: price}, :monthly), do: {:ok, price}
  def price_for(%Plan{annual_price_cents: price}, :annual), do: {:ok, price}
  def price_for(%Plan{}, _cycle), do: {:error, :invalid_cycle}

  @doc "Returns true if the plan includes the given feature."
  @spec has_feature?(Plan.t(), atom()) :: boolean()
  def has_feature?(%Plan{features: features}, feature) when is_atom(feature) do
    feature in features
  end

  @doc "Returns true if `candidate` is an upgrade from `current`."
  @spec upgrade?(Plan.t(), Plan.t()) :: boolean()
  def upgrade?(%Plan{monthly_price_cents: current}, %Plan{monthly_price_cents: candidate}) do
    candidate > current
  end

  @doc """
  Validates that a seat count is within the plan's limit.
  Returns `:ok` or `{:error, :seat_limit_exceeded}`.
  """
  @spec validate_seat_count(Plan.t(), pos_integer()) ::
          :ok | {:error, :seat_limit_exceeded}
  def validate_seat_count(%Plan{max_seats: :unlimited}, _count), do: :ok

  def validate_seat_count(%Plan{max_seats: max}, count)
      when is_integer(count) and count <= max do
    :ok
  end

  def validate_seat_count(%Plan{}, _count), do: {:error, :seat_limit_exceeded}
end

defmodule Billing.Subscriptions.Plan do
  @moduledoc "Struct representing a subscription plan."

  @enforce_keys [:id, :name, :monthly_price_cents, :annual_price_cents, :max_seats, :features]
  defstruct [:id, :name, :monthly_price_cents, :annual_price_cents, :max_seats, :features]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          monthly_price_cents: pos_integer(),
          annual_price_cents: pos_integer(),
          max_seats: pos_integer() | :unlimited,
          features: [atom()]
        }
end
```
