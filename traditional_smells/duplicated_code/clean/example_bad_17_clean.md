```elixir
defmodule Warehouse.LocationManager do
  @moduledoc """
  Manages physical storage bin assignments in a warehouse.
  Handles put-away, relocation, and retrieval operations.
  """

  alias Warehouse.Repo
  alias Warehouse.Bin
  alias Warehouse.StoredItem
  alias Warehouse.Item

  @doc """
  Places an item into a storage bin.
  Validates that the bin has sufficient free capacity.
  """
  def put_away(%Item{} = item, %Bin{} = bin, quantity) do
    used_volume =
      Repo.all_by(StoredItem, bin_id: bin.id)
      |> Enum.reduce(0.0, fn si, acc -> acc + si.item.volume_m3 * si.quantity end)

    free_capacity = bin.max_volume_m3 - used_volume
    required_volume = item.volume_m3 * quantity

    if required_volume > free_capacity do
      {:error, {:insufficient_capacity, %{available: free_capacity, required: required_volume}}}
    else
      stored = %StoredItem{
        bin_id: bin.id,
        item_id: item.id,
        quantity: quantity,
        put_away_at: DateTime.utc_now()
      }

      Repo.insert(stored)
      {:ok, stored}
    end
  end

  @doc """
  Moves a stored item from its current bin to a target bin.
  Validates capacity at the destination before moving.
  """
  def relocate(%StoredItem{} = stored_item, %Bin{} = target_bin, quantity) do
    item = Repo.get!(Item, stored_item.item_id)

    used_volume =
      Repo.all_by(StoredItem, bin_id: target_bin.id)
      |> Enum.reduce(0.0, fn si, acc -> acc + si.item.volume_m3 * si.quantity end)

    free_capacity = target_bin.max_volume_m3 - used_volume
    required_volume = item.volume_m3 * quantity

    if required_volume > free_capacity do
      {:error, {:insufficient_capacity, %{available: free_capacity, required: required_volume}}}
    else
      if stored_item.quantity == quantity do
        Repo.update(%{stored_item | bin_id: target_bin.id})
      else
        Repo.update(%{stored_item | quantity: stored_item.quantity - quantity})
        new_entry = %StoredItem{bin_id: target_bin.id, item_id: stored_item.item_id, quantity: quantity}
        Repo.insert(new_entry)
      end

      {:ok, :relocated}
    end
  end

  @doc """
  Returns the current occupancy percentage for a bin.
  """
  def occupancy_percent(%Bin{} = bin) do
    used =
      Repo.all_by(StoredItem, bin_id: bin.id)
      |> Enum.reduce(0.0, fn si, acc -> acc + si.item.volume_m3 * si.quantity end)

    Float.round(used / bin.max_volume_m3 * 100, 1)
  end

  @doc """
  Lists all bins with occupancy above the given threshold (0–100).
  """
  def bins_above_threshold(threshold) do
    Repo.all(Bin)
    |> Enum.filter(fn bin -> occupancy_percent(bin) > threshold end)
  end
end
```
