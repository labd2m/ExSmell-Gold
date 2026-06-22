```elixir
defmodule Warehouse.BinAssigner do
  @moduledoc """
  Assigns storage bin locations to incoming stock using a configurable
  placement strategy. Supported strategies are: first-available,
  nearest-to-dispatch, and zone-matched. Each strategy is a module
  implementing the `Warehouse.PlacementStrategy` behaviour. The assigner
  is pure; the caller supplies the bin inventory so results are fully
  testable without database access.
  """

  @type bin :: %{
          id: String.t(),
          zone: String.t(),
          aisle: String.t(),
          sequence: non_neg_integer(),
          capacity: pos_integer(),
          occupied: non_neg_integer()
        }

  @type sku :: String.t()
  @type assignment_request :: %{sku: sku(), quantity: pos_integer(), zone_preference: String.t() | nil}
  @type assignment :: %{bin_id: String.t(), quantity: non_neg_integer()}
  @type assign_result :: {:ok, [assignment()]} | {:error, :insufficient_capacity}

  @doc """
  Assigns `request` across available `bins` using `strategy_module`.
  Splits across multiple bins when no single bin has sufficient space.
  Returns `{:error, :insufficient_capacity}` when total available space
  is less than the requested quantity.
  """
  @spec assign([bin()], assignment_request(), module()) :: assign_result()
  def assign(bins, %{quantity: qty} = request, strategy_module)
      when is_list(bins) and is_integer(qty) and qty > 0 do
    available = bins |> Enum.filter(&available?/1) |> strategy_module.sort(request)
    total_space = Enum.sum_by(available, &free_space/1)

    if total_space < qty do
      {:error, :insufficient_capacity}
    else
      {:ok, split_across_bins(available, qty)}
    end
  end

  @doc "Returns the available space in a bin."
  @spec free_space(bin()) :: non_neg_integer()
  def free_space(%{capacity: cap, occupied: occ}), do: cap - occ

  @doc "Returns true when a bin has any available space."
  @spec available?(bin()) :: boolean()
  def available?(bin), do: free_space(bin) > 0

  defp split_across_bins(bins, remaining) do
    {assignments, _} =
      Enum.reduce_while(bins, {[], remaining}, fn bin, {acc, left} ->
        if left == 0 do
          {:halt, {acc, 0}}
        else
          take = min(free_space(bin), left)
          assignment = %{bin_id: bin.id, quantity: take}
          {:cont, {[assignment | acc], left - take}}
        end
      end)

    Enum.reverse(assignments)
  end
end

defmodule Warehouse.PlacementStrategy do
  @moduledoc "Behaviour for bin sorting strategies used by `Warehouse.BinAssigner`."

  @doc "Sorts `bins` according to the strategy's placement logic."
  @callback sort([Warehouse.BinAssigner.bin()], Warehouse.BinAssigner.assignment_request()) ::
              [Warehouse.BinAssigner.bin()]
end

defmodule Warehouse.Strategy.FirstAvailable do
  @moduledoc "Sorts bins by aisle then sequence — first available placement."

  @behaviour Warehouse.PlacementStrategy

  @impl Warehouse.PlacementStrategy
  def sort(bins, _request) do
    Enum.sort_by(bins, fn b -> {b.aisle, b.sequence} end)
  end
end

defmodule Warehouse.Strategy.ZoneMatched do
  @moduledoc "Prioritises bins in the preferred zone, falling back to any available bin."

  @behaviour Warehouse.PlacementStrategy

  @impl Warehouse.PlacementStrategy
  def sort(bins, %{zone_preference: zone}) when is_binary(zone) do
    Enum.sort_by(bins, fn b ->
      {if(b.zone == zone, do: 0, else: 1), b.aisle, b.sequence}
    end)
  end

  def sort(bins, _request), do: Enum.sort_by(bins, &{&1.aisle, &1.sequence})
end
```
