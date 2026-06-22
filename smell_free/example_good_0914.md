```elixir
defmodule Logistics.RouteValidator do
  @moduledoc """
  Validates shipment routing plans against carrier service constraints.
  Each constraint is a named rule with a predicate and an error message.
  Constraints are evaluated in order; all violations are collected and
  returned together so the caller can present a complete error list rather
  than forcing the user through one issue at a time. All functions are pure.
  """

  @type constraint_name :: atom()
  @type shipment :: %{
          origin_country: String.t(),
          destination_country: String.t(),
          weight_grams: pos_integer(),
          contains_hazmat: boolean(),
          declared_value_cents: non_neg_integer(),
          service_class: atom()
        }

  @type carrier_rules :: %{
          allowed_origins: [String.t()],
          allowed_destinations: [String.t()],
          max_weight_grams: pos_integer(),
          hazmat_permitted: boolean(),
          max_declared_value_cents: non_neg_integer() | :unlimited,
          allowed_service_classes: [atom()]
        }

  @type violation :: %{rule: constraint_name(), message: String.t()}
  @type validate_result :: :ok | {:error, [violation()]}

  @doc """
  Validates `shipment` against `carrier_rules`. Returns `:ok` when all
  constraints pass or `{:error, violations}` listing every failing rule.
  """
  @spec validate(shipment(), carrier_rules()) :: validate_result()
  def validate(%{} = shipment, %{} = rules) do
    violations =
      all_constraints()
      |> Enum.flat_map(fn {name, check_fn} ->
        case check_fn.(shipment, rules) do
          :ok -> []
          {:error, msg} -> [%{rule: name, message: msg}]
        end
      end)

    if Enum.empty?(violations), do: :ok, else: {:error, violations}
  end

  @doc "Returns the list of active constraint names."
  @spec constraint_names() :: [constraint_name()]
  def constraint_names, do: Enum.map(all_constraints(), fn {name, _} -> name end)

  defp all_constraints do
    [
      {:origin_allowed, &check_origin/2},
      {:destination_allowed, &check_destination/2},
      {:weight_limit, &check_weight/2},
      {:hazmat_restriction, &check_hazmat/2},
      {:declared_value_limit, &check_declared_value/2},
      {:service_class_allowed, &check_service_class/2}
    ]
  end

  defp check_origin(%{origin_country: origin}, %{allowed_origins: allowed}) do
    if origin in allowed, do: :ok,
      else: {:error, "origin country '#{origin}' is not serviced by this carrier"}
  end

  defp check_destination(%{destination_country: dest}, %{allowed_destinations: allowed}) do
    if dest in allowed, do: :ok,
      else: {:error, "destination country '#{dest}' is not serviced by this carrier"}
  end

  defp check_weight(%{weight_grams: weight}, %{max_weight_grams: max}) do
    if weight <= max, do: :ok,
      else: {:error, "parcel weight #{weight}g exceeds carrier maximum of #{max}g"}
  end

  defp check_hazmat(%{contains_hazmat: true}, %{hazmat_permitted: false}) do
    {:error, "this carrier does not permit hazardous materials"}
  end
  defp check_hazmat(_, _), do: :ok

  defp check_declared_value(_, %{max_declared_value_cents: :unlimited}), do: :ok
  defp check_declared_value(%{declared_value_cents: value}, %{max_declared_value_cents: max}) do
    if value <= max, do: :ok,
      else: {:error, "declared value #{value} cents exceeds carrier limit of #{max} cents"}
  end

  defp check_service_class(%{service_class: svc}, %{allowed_service_classes: allowed}) do
    if svc in allowed, do: :ok,
      else: {:error, "service class '#{svc}' is not available for this carrier"}
  end
end
```
