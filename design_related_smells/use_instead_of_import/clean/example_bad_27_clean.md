```elixir
defmodule Shipping.WeightHelpers do
  @moduledoc """
  Stateless helpers for weight conversion, dimensional-weight computation,
  and shipment-weight classification.
  """

  def kg_to_lb(kg) when is_number(kg),   do: Float.round(kg * 2.20462, 3)
  def lb_to_kg(lb) when is_number(lb),   do: Float.round(lb / 2.20462, 3)
  def g_to_kg(g) when is_number(g),      do: g / 1_000
  def oz_to_lb(oz) when is_number(oz),   do: Float.round(oz / 16, 3)

  def dimensional_weight_kg(length_cm, width_cm, height_cm, divisor \\ 5_000) do
    volume = length_cm * width_cm * height_cm
    Float.round(volume / divisor, 2)
  end

  def billable_weight(actual_kg, dim_kg) do
    max(actual_kg, dim_kg)
  end

  def weight_class(kg) when kg <= 0.5,  do: :letter
  def weight_class(kg) when kg <= 2.0,  do: :small_parcel
  def weight_class(kg) when kg <= 10.0, do: :medium_parcel
  def weight_class(kg) when kg <= 30.0, do: :large_parcel
  def weight_class(_),                  do: :freight

  def oversize?(%{length: l, width: w, height: h}) do
    l + 2 * (w + h) > 330
  end

  defmacro __using__(_opts) do
    quote do
      import Shipping.WeightHelpers
      alias Shipping.CarrierPricing

      @dim_divisor 5_000
      @weight_unit :kg
    end
  end
end

defmodule Shipping.CarrierPricing do
  @moduledoc "Stub for carrier rate lookups by service level and weight."

  def rate(:standard, kg) when kg <= 1,    do: 5.99
  def rate(:standard, kg) when kg <= 5,    do: 9.99
  def rate(:standard, _kg),                do: 14.99
  def rate(:express, kg) when kg <= 1,     do: 12.99
  def rate(:express, kg) when kg <= 5,     do: 19.99
  def rate(:express, _kg),                 do: 29.99
  def rate(:overnight, _kg),               do: 49.99
  def rate(_, _),                          do: 99.99

  def available_services(:letter),         do: [:standard]
  def available_services(:small_parcel),   do: [:standard, :express]
  def available_services(:medium_parcel),  do: [:standard, :express, :overnight]
  def available_services(:large_parcel),   do: [:standard, :express]
  def available_services(:freight),        do: [:standard]
end

defmodule Shipping.RateEstimator do
  use Shipping.WeightHelpers

  @moduledoc """
  Estimates shipping rates for parcels using carrier pricing, dimensional weight,
  and billable weight computation. Returns quotes for all available service levels.
  """

  defstruct [:origin, :destination, :weight_kg, :dimensions, :billable_kg, :weight_class, :quotes]

  def estimate(%{weight_kg: wt, dimensions: dims} = parcel, opts \\ []) do
    dim_wt    = dimensional_weight_kg(dims.length, dims.width, dims.height, @dim_divisor)
    bill_wt   = billable_weight(wt, dim_wt)
    w_class   = weight_class(bill_wt)
    services  = CarrierPricing.available_services(w_class)
    is_over   = oversize?(dims)

    quotes =
      Enum.map(services, fn svc ->
        base       = CarrierPricing.rate(svc, bill_wt)
        surcharges = surcharge_total(parcel, is_over)
        total      = Float.round(base + surcharges, 2)
        %{service: svc, base_rate: base, surcharges: surcharges, total: total}
      end)

    %__MODULE__{
      origin:       opts[:origin],
      destination:  opts[:destination],
      weight_kg:    wt,
      dimensions:   dims,
      billable_kg:  bill_wt,
      weight_class: w_class,
      quotes:       quotes
    }
  end

  def cheapest_option(%__MODULE__{quotes: quotes}) do
    Enum.min_by(quotes, & &1.total, fn -> nil end)
  end

  def dimensional_weight(%__MODULE__{dimensions: d}) do
    dimensional_weight_kg(d.length, d.width, d.height, @dim_divisor)
  end

  def surcharge_total(%{declared_value: val}, oversize?) when is_number(val) do
    insurance = val * 0.01
    oversize  = if oversize?, do: 12.50, else: 0.0
    Float.round(insurance + oversize, 2)
  end

  def surcharge_total(_, oversize?) do
    if oversize?, do: 12.50, else: 0.0
  end

  def render(%__MODULE__{} = est) do
    header  = "Shipping Estimate | #{est.weight_kg}#{@weight_unit} | Billable: #{est.billable_kg}#{@weight_unit}"
    lines   = Enum.map_join(est.quotes, "\n", fn q ->
      "  #{q.service}: base=#{q.base_rate} + surcharges=#{q.surcharges} = #{q.total}"
    end)
    "#{header}\n#{lines}"
  end
end
```
