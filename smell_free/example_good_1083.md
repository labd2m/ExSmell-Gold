```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages warehouse stock levels for SKUs. Provides reservation,
  release, and adjustment operations with optimistic concurrency via Ecto.
  """

  alias Inventory.{Repo, StockEntry}
  alias Ecto.Multi

  @type sku :: String.t()
  @type quantity :: pos_integer()

  @spec reserve(sku(), quantity()) ::
          {:ok, StockEntry.t()} | {:error, :insufficient_stock | Ecto.Changeset.t()}
  def reserve(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    Multi.new()
    |> Multi.run(:entry, fn repo, _ -> fetch_for_update(repo, sku) end)
    |> Multi.run(:reserved, fn repo, %{entry: entry} ->
      apply_reservation(repo, entry, quantity)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{reserved: entry}} -> {:ok, entry}
      {:error, :entry, reason, _} -> {:error, reason}
      {:error, :reserved, reason, _} -> {:error, reason}
    end
  end

  @spec release(sku(), quantity()) :: {:ok, StockEntry.t()} | {:error, atom()}
  def release(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    Multi.new()
    |> Multi.run(:entry, fn repo, _ -> fetch_for_update(repo, sku) end)
    |> Multi.run(:released, fn repo, %{entry: entry} ->
      apply_release(repo, entry, quantity)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{released: entry}} -> {:ok, entry}
      {:error, :entry, reason, _} -> {:error, reason}
      {:error, :released, changeset, _} -> {:error, changeset}
    end
  end

  @spec adjust(sku(), integer()) :: {:ok, StockEntry.t()} | {:error, Ecto.Changeset.t()}
  def adjust(sku, delta) when is_binary(sku) and is_integer(delta) do
    case Repo.get_by(StockEntry, sku: sku) do
      nil -> {:error, :not_found}
      entry -> entry |> StockEntry.adjustment_changeset(delta) |> Repo.update()
    end
  end

  @spec fetch_for_update(Ecto.Repo.t(), sku()) :: {:ok, StockEntry.t()} | {:error, :not_found}
  defp fetch_for_update(repo, sku) do
    case repo.get_by(StockEntry, sku: sku, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @spec apply_reservation(Ecto.Repo.t(), StockEntry.t(), quantity()) ::
          {:ok, StockEntry.t()} | {:error, :insufficient_stock | Ecto.Changeset.t()}
  defp apply_reservation(repo, entry, quantity) do
    if entry.available_quantity >= quantity do
      entry |> StockEntry.reservation_changeset(quantity) |> repo.update()
    else
      {:error, :insufficient_stock}
    end
  end

  @spec apply_release(Ecto.Repo.t(), StockEntry.t(), quantity()) ::
          {:ok, StockEntry.t()} | {:error, Ecto.Changeset.t()}
  defp apply_release(repo, entry, quantity) do
    entry |> StockEntry.release_changeset(quantity) |> repo.update()
  end
end
```
