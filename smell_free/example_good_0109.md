```elixir
defmodule Shipping.Address do
  @moduledoc "Value struct representing a validated postal delivery address."

  @enforce_keys [:line1, :city, :country_code, :postal_code]
  defstruct [:line1, :line2, :city, :state, :country_code, :postal_code]

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state: String.t() | nil,
          country_code: String.t(),
          postal_code: String.t()
        }
end

defmodule Shipping.RateCalculator do
  @moduledoc """
  Calculates shipping rates based on parcel dimensions, weight, and the
  origin/destination country pairing. Rate tables are loaded from application
  configuration at startup and accessed at call time, enabling runtime
  updates without recompilation.
  """

  alias Shipping.Address

  @type weight_grams :: pos_integer()
  @type dimensions :: %{length_cm: number(), width_cm: number(), height_cm: number()}
  @type service_class :: :standard | :express | :overnight

  @type rate_result :: %{
          service: service_class(),
          currency: String.t(),
          amount_cents: non_neg_integer(),
          estimated_days: pos_integer()
        }

  @type rate_error :: :unserviceable_route | :parcel_too_heavy | :parcel_too_large

  @max_weight_grams 30_000
  @max_volume_cm3 40_000

  @doc """
  Returns available shipping rates for a parcel travelling from `origin` to
  `destination`. Returns all serviceable classes sorted by price ascending.
  """
  @spec available_rates(Address.t(), Address.t(), weight_grams(), dimensions()) ::
          {:ok, [rate_result()]} | {:error, rate_error()}
  def available_rates(%Address{} = origin, %Address{} = dest, weight, dims)
      when is_integer(weight) and weight > 0 and is_map(dims) do
    with :ok <- validate_weight(weight),
         :ok <- validate_volume(dims),
         {:ok, table} <- fetch_rate_table(origin.country_code, dest.country_code) do
      rates = Enum.map(table, fn {service, config} -> build_rate(service, config, weight, dims) end)
      {:ok, Enum.sort_by(rates, & &1.amount_cents)}
    end
  end

  defp validate_weight(weight) when weight > @max_weight_grams, do: {:error, :parcel_too_heavy}
  defp validate_weight(_weight), do: :ok

  defp validate_volume(%{length_cm: l, width_cm: w, height_cm: h}) do
    if l * w * h > @max_volume_cm3, do: {:error, :parcel_too_large}, else: :ok
  end

  defp fetch_rate_table(origin_cc, dest_cc) do
    tables = Application.get_env(:my_app, :shipping_rate_tables, %{})
    route_key = "#{origin_cc}→#{dest_cc}"

    case Map.get(tables, route_key) do
      nil -> {:error, :unserviceable_route}
      table -> {:ok, table}
    end
  end

  defp build_rate(service, config, weight, dims) do
    base = config[:base_cents]
    per_kg = config[:cents_per_kg]
    volume_divisor = config[:volume_divisor] || 5000
    vol_weight = volume_weight(dims, volume_divisor)
    billable_weight = max(weight, vol_weight)
    amount = base + round(billable_weight / 1000 * per_kg)

    %{
      service: service,
      currency: config[:currency] || "USD",
      amount_cents: amount,
      estimated_days: config[:days]
    }
  end

  defp volume_weight(%{length_cm: l, width_cm: w, height_cm: h}, divisor) do
    round(l * w * h / divisor * 1000)
  end
end
```
