```elixir
defmodule MyApp.Shipping.RateCalculator do
  @moduledoc """
  Calculates shipping rates for a given parcel and destination address
  by querying registered carrier adapters in parallel. Adapters are
  declared as a list of modules that implement the `MyApp.Shipping.Adapter`
  behaviour. Unresponsive or erroring adapters are excluded from the
  result rather than failing the entire request.
  """

  alias MyApp.Shipping.{Parcel, Address, Rate}

  @adapters [
    MyApp.Shipping.Adapters.UPS,
    MyApp.Shipping.Adapters.FedEx,
    MyApp.Shipping.Adapters.USPS
  ]

  @query_timeout_ms 5_000

  @type quote_result :: {:ok, [Rate.t()]} | {:error, term()}

  @doc """
  Returns all available rates for shipping `parcel` to `destination`,
  sorted by total price ascending. Carriers that time out or return
  errors are silently dropped from the response.
  """
  @spec available_rates(Parcel.t(), Address.t()) :: {:ok, [Rate.t()]}
  def available_rates(%Parcel{} = parcel, %Address{} = destination) do
    rates =
      @adapters
      |> Task.async_stream(
        fn adapter -> query_adapter(adapter, parcel, destination) end,
        timeout: @query_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Stream.flat_map(&extract_rates/1)
      |> Enum.sort_by(& &1.total_cents)

    {:ok, rates}
  end

  @doc """
  Returns the cheapest available rate, or `{:error, :no_rates_available}`
  when all carriers fail to respond.
  """
  @spec cheapest_rate(Parcel.t(), Address.t()) ::
          {:ok, Rate.t()} | {:error, :no_rates_available}
  def cheapest_rate(%Parcel{} = parcel, %Address{} = destination) do
    case available_rates(parcel, destination) do
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> {:error, :no_rates_available}
    end
  end

  @spec query_adapter(module(), Parcel.t(), Address.t()) :: quote_result()
  defp query_adapter(adapter, parcel, destination) do
    adapter.fetch_rates(parcel, destination)
  rescue
    error ->
      require Logger
      Logger.warning("shipping_adapter_error", adapter: adapter, error: inspect(error))
      {:error, :adapter_exception}
  end

  @spec extract_rates({:ok, quote_result()} | {:exit, term()}) :: [Rate.t()]
  defp extract_rates({:ok, {:ok, rates}}) when is_list(rates), do: rates
  defp extract_rates(_), do: []
end

defmodule MyApp.Shipping.Parcel do
  @moduledoc "Describes the physical dimensions and weight of a shipment."

  @enforce_keys [:weight_grams, :length_cm, :width_cm, :height_cm]
  defstruct [:weight_grams, :length_cm, :width_cm, :height_cm, :insured_value_cents]

  @type t :: %__MODULE__{
          weight_grams: pos_integer(),
          length_cm: pos_integer(),
          width_cm: pos_integer(),
          height_cm: pos_integer(),
          insured_value_cents: non_neg_integer() | nil
        }
end

defmodule MyApp.Shipping.Rate do
  @moduledoc "A single shipping rate option returned by a carrier adapter."

  @enforce_keys [:carrier, :service, :total_cents, :estimated_days]
  defstruct [:carrier, :service, :total_cents, :estimated_days, :tracking_available]

  @type t :: %__MODULE__{
          carrier: String.t(),
          service: String.t(),
          total_cents: pos_integer(),
          estimated_days: pos_integer(),
          tracking_available: boolean()
        }
end
```
