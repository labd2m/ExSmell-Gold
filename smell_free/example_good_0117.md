```elixir
defmodule Subscriptions.PlanRegistry do
  @moduledoc """
  Manages the catalogue of available subscription plans. Plans are loaded
  from application configuration at runtime so they can be updated without
  redeployment. Feature entitlements are centralised here to avoid
  dispersed conditionals across billing, usage, and access modules.
  """

  @enforce_keys [:id, :name, :price_cents, :currency, :interval, :features]
  defstruct [:id, :name, :price_cents, :currency, :interval, :features,
             trial_days: 0, active: true]

  @type interval :: :monthly | :annual
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          price_cents: non_neg_integer(),
          currency: String.t(),
          interval: interval(),
          features: MapSet.t(atom()),
          trial_days: non_neg_integer(),
          active: boolean()
        }

  @doc """
  Returns all active plans sorted by price ascending. Plans are loaded
  from application config on each call to reflect runtime changes.
  """
  @spec active_plans() :: [t()]
  def active_plans do
    load_plans()
    |> Enum.filter(& &1.active)
    |> Enum.sort_by(& &1.price_cents)
  end

  @doc "Returns the plan with the given ID, or `{:error, :not_found}`."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, :not_found}
  def fetch(plan_id) when is_binary(plan_id) do
    case Enum.find(load_plans(), fn p -> p.id == plan_id end) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  @doc "Returns true when the plan grants the specified feature."
  @spec grants_feature?(t(), atom()) :: boolean()
  def grants_feature?(%__MODULE__{features: features}, feature) when is_atom(feature) do
    MapSet.member?(features, feature)
  end

  @doc "Returns the monthly equivalent price in cents regardless of billing interval."
  @spec monthly_price_cents(t()) :: non_neg_integer()
  def monthly_price_cents(%__MODULE__{interval: :monthly, price_cents: p}), do: p
  def monthly_price_cents(%__MODULE__{interval: :annual, price_cents: p}), do: div(p, 12)

  @doc "Compares two plans, returning `:upgrade`, `:downgrade`, or `:same`."
  @spec compare(t(), t()) :: :upgrade | :downgrade | :same
  def compare(%__MODULE__{} = from_plan, %__MODULE__{} = to_plan) do
    from_price = monthly_price_cents(from_plan)
    to_price = monthly_price_cents(to_plan)

    cond do
      to_price > from_price -> :upgrade
      to_price < from_price -> :downgrade
      true -> :same
    end
  end

  defp load_plans do
    :my_app
    |> Application.get_env(:subscription_plans, [])
    |> Enum.map(&build_plan/1)
  end

  defp build_plan(attrs) do
    %__MODULE__{
      id: attrs[:id],
      name: attrs[:name],
      price_cents: attrs[:price_cents],
      currency: attrs[:currency] || "USD",
      interval: attrs[:interval] || :monthly,
      features: MapSet.new(attrs[:features] || []),
      trial_days: attrs[:trial_days] || 0,
      active: Map.get(attrs, :active, true)
    }
  end
end
```
