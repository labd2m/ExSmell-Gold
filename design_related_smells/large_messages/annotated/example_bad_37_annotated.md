# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Fulfilment.BatchProcessor.cast_work_order/2` |
| **Affected function(s)** | `cast_work_order/2` |
| **Short explanation** | The batch processor loads the full set of open orders for a fulfilment centre—each with complete item lines, customer addresses, carrier quotes, and picking instructions—and sends them all in one `GenServer.cast` message to a packing worker process. The message size can be enormous when thousands of orders are pending. |

```elixir
defmodule Fulfilment.Address do
  defstruct [:line1, :line2, :city, :state, :postcode, :country, :phone]

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state: String.t(),
          postcode: String.t(),
          country: String.t(),
          phone: String.t() | nil
        }
end

defmodule Fulfilment.OrderLine do
  defstruct [:line_id, :sku, :name, :qty, :unit_weight_g, :bin_location, :barcode, :hazmat]

  @type t :: %__MODULE__{
          line_id: String.t(),
          sku: String.t(),
          name: String.t(),
          qty: pos_integer(),
          unit_weight_g: float(),
          bin_location: String.t(),
          barcode: String.t(),
          hazmat: boolean()
        }
end

defmodule Fulfilment.CarrierQuote do
  defstruct [:carrier, :service, :transit_days, :price, :tracking_url_template]

  @type t :: %__MODULE__{
          carrier: String.t(),
          service: String.t(),
          transit_days: pos_integer(),
          price: float(),
          tracking_url_template: String.t()
        }
end

defmodule Fulfilment.Order do
  @enforce_keys [:id, :customer_id, :ship_to, :lines, :carrier_quotes, :status]
  defstruct [
    :id,
    :customer_id,
    :ship_to,
    :lines,
    :carrier_quotes,
    :status,
    :priority,
    :notes,
    :promised_by,
    :customs_info,
    :gift_message
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          ship_to: Fulfilment.Address.t(),
          lines: [Fulfilment.OrderLine.t()],
          carrier_quotes: [Fulfilment.CarrierQuote.t()],
          status: :pending | :allocated | :picking | :packed | :shipped,
          priority: :standard | :express | :next_day,
          notes: String.t() | nil,
          promised_by: DateTime.t(),
          customs_info: map() | nil,
          gift_message: String.t() | nil
        }
end

defmodule Fulfilment.OrderStore do
  @moduledoc "Provides access to open orders for a fulfilment centre."

  @spec fetch_open_orders(String.t()) :: [Fulfilment.Order.t()]
  def fetch_open_orders(centre_id) do
    now = DateTime.utc_now()

    Enum.map(1..12_000, fn n ->
      %Fulfilment.Order{
        id: "ORD-#{centre_id}-#{String.pad_leading("#{n}", 8, "0")}",
        customer_id: "CUST-#{rem(n, 200_000) + 1}",
        priority: Enum.random([:standard, :standard, :express, :next_day]),
        status: :pending,
        promised_by: DateTime.add(now, :rand.uniform(72) * 3600, :second),
        notes: if(rem(n, 20) == 0, do: "Leave in safe place. Ref #{n}."),
        gift_message: if(rem(n, 50) == 0, do: "Happy Birthday! Enjoy your gift."),
        customs_info:
          if rem(n, 10) == 0 do
            %{
              declared_value: Float.round(:rand.uniform() * 200, 2),
              hs_code: "#{rem(n, 9_999_999) + 1_000_000}",
              contents_description: "Consumer electronics accessories",
              country_of_origin: "CN"
            }
          end,
        ship_to: %Fulfilment.Address{
          line1: "#{rem(n, 9999) + 1} Delivery Road",
          line2: if(rem(n, 5) == 0, do: "Apt #{rem(n, 200) + 1}"),
          city: "City #{rem(n, 300) + 1}",
          state: "ST",
          postcode: "#{rem(n, 90000) + 10000}",
          country: "US",
          phone: "+1555#{String.pad_leading("#{rem(n, 9_999_999)}", 7, "0")}"
        },
        lines:
          Enum.map(1..12, fn l ->
            %Fulfilment.OrderLine{
              line_id: "LINE-#{n}-#{l}",
              sku: "SKU-#{rem(n * l, 100_000)}",
              name: "Item #{rem(n * l, 100_000)} – Standard Pack",
              qty: :rand.uniform(5),
              unit_weight_g: :rand.uniform() * 2000 + 100,
              bin_location: "#{<<65 + rem(l, 26)::utf8>>}-#{rem(n, 99) + 1}-B#{rem(l, 9) + 1}",
              barcode: "89#{String.pad_leading("#{rem(n * l, 99_999_999)}", 10, "0")}",
              hazmat: rem(l, 30) == 0
            }
          end),
        carrier_quotes:
          Enum.map(["UPS", "FedEx", "USPS", "DHL"], fn carrier ->
            %Fulfilment.CarrierQuote{
              carrier: carrier,
              service: Enum.random(["Ground", "Express", "Priority"]),
              transit_days: :rand.uniform(7),
              price: Float.round(3.0 + :rand.uniform() * 30, 2),
              tracking_url_template: "https://track.#{String.downcase(carrier)}.com/{tracking_number}"
            }
          end)
      }
    end)
  end
end

defmodule Fulfilment.PackingWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:work_order, centre_id, orders}, _state) do
    {:noreply, {centre_id, length(orders)}}
  end
end

defmodule Fulfilment.BatchProcessor do
  @moduledoc """
  Loads all pending orders for a fulfilment centre and sends them to
  the packing worker to begin allocation and picking.
  """

  require Logger

  @spec cast_work_order(pid(), String.t()) :: :ok
  def cast_work_order(packing_pid, centre_id) do
    Logger.info("Fetching open orders for centre #{centre_id}...")

    orders = Fulfilment.OrderStore.fetch_open_orders(centre_id)

    Logger.info(
      "Loaded #{length(orders)} open orders for centre #{centre_id}. " <>
        "Dispatching work order to packing worker..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `orders` is a list of 12,000 Order
    # structs, each containing 12 OrderLine structs, 4 CarrierQuote structs,
    # a ship-to Address, optional customs_info maps, and string fields.
    # Sending all of this in one cast message requires the BEAM to deep-copy
    # the complete structure to the packing worker's heap, blocking the
    # BatchProcessor process during the entire copy and potentially causing
    # timeouts in other callers waiting for it.
    GenServer.cast(packing_pid, {:work_order, centre_id, orders})
    # VALIDATION: SMELL END

    Logger.info("Work order dispatched for centre #{centre_id}.")
    :ok
  end
end
```
