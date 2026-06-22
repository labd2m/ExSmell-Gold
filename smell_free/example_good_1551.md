```elixir
defmodule Marketplace.ListingContext do
  @moduledoc """
  Domain context governing the full lifecycle of marketplace listings.

  Listings progress through a defined set of states: `:draft`, `:active`,
  `:paused`, and `:closed`. Price and inventory updates are only permitted
  on active listings. All state transitions are validated before persistence.
  """

  alias Marketplace.{Listing, ListingHistory, Repo}
  alias Ecto.Multi

  @type listing_attrs :: %{
          seller_id: String.t(),
          title: String.t(),
          description: String.t(),
          price_cents: pos_integer(),
          quantity: pos_integer(),
          category_id: pos_integer()
        }

  @type update_result ::
          {:ok, Listing.t()}
          | {:error, :listing_not_found}
          | {:error, :invalid_state_for_update}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Creates a new listing in draft state for the given seller.
  """
  @spec create_draft(listing_attrs()) :: {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def create_draft(attrs) when is_map(attrs) do
    %Listing{}
    |> Listing.changeset(Map.put(attrs, :status, :draft))
    |> Repo.insert()
  end

  @doc """
  Activates a draft listing, making it visible in the marketplace.
  """
  @spec activate(Ecto.UUID.t()) :: update_result()
  def activate(listing_id) when is_binary(listing_id) do
    transition_state(listing_id, :draft, :active)
  end

  @doc """
  Pauses an active listing, hiding it temporarily from buyers.
  """
  @spec pause(Ecto.UUID.t()) :: update_result()
  def pause(listing_id) when is_binary(listing_id) do
    transition_state(listing_id, :active, :paused)
  end

  @doc """
  Closes a listing permanently. Closed listings cannot be reopened.
  """
  @spec close(Ecto.UUID.t()) :: update_result()
  def close(listing_id) when is_binary(listing_id) do
    with {:ok, listing} <- fetch_listing(listing_id) do
      if listing.status == :closed do
        {:error, :invalid_state_for_update}
      else
        perform_state_transition(listing, :closed)
      end
    end
  end

  @doc """
  Updates price and quantity on an active listing.
  """
  @spec update_pricing(Ecto.UUID.t(), pos_integer(), pos_integer()) :: update_result()
  def update_pricing(listing_id, new_price_cents, new_quantity) do
    with {:ok, %Listing{status: :active} = listing} <- fetch_listing(listing_id) do
      listing
      |> Listing.changeset(%{price_cents: new_price_cents, quantity: new_quantity})
      |> Repo.update()
    else
      {:ok, _} -> {:error, :invalid_state_for_update}
      {:error, _} = err -> err
    end
  end

  defp transition_state(listing_id, required_state, target_state) do
    with {:ok, listing} <- fetch_listing(listing_id) do
      if listing.status == required_state do
        perform_state_transition(listing, target_state)
      else
        {:error, :invalid_state_for_update}
      end
    end
  end

  defp fetch_listing(listing_id) do
    case Repo.get(Listing, listing_id) do
      nil -> {:error, :listing_not_found}
      listing -> {:ok, listing}
    end
  end

  defp perform_state_transition(listing, new_state) do
    Multi.new()
    |> Multi.update(:listing, Listing.changeset(listing, %{
      status: new_state,
      status_changed_at: DateTime.utc_now()
    }))
    |> Multi.insert(:history, fn %{listing: updated} ->
      ListingHistory.changeset(%ListingHistory{}, %{
        listing_id: updated.id,
        from_state: listing.status,
        to_state: new_state,
        transitioned_at: DateTime.utc_now()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{listing: updated}} -> {:ok, updated}
      {:error, :listing, changeset, _} -> {:error, changeset}
    end
  end
end
```
