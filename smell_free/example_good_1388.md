```elixir
defmodule Marketplace.Auctions.BidProcessor do
  @moduledoc """
  Processes bids in real-time for live auction lots.
  Bids are validated against reserve price, increment rules, and bidder eligibility.
  The leading bid is tracked atomically via a supervised GenServer.
  """

  use GenServer

  @type lot_id :: String.t()
  @type bidder_id :: String.t()
  @type bid :: %{bidder_id: bidder_id(), amount_cents: pos_integer(), placed_at: DateTime.t()}
  @type lot_state :: %{
          lot_id: lot_id(),
          reserve_cents: pos_integer(),
          min_increment_cents: pos_integer(),
          leading_bid: bid() | nil,
          bid_count: non_neg_integer(),
          open: boolean()
        }
  @type state :: %{lots: %{lot_id() => lot_state()}}

  @doc """
  Starts the BidProcessor linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Opens a new auction lot for bidding.
  """
  @spec open_lot(lot_id(), pos_integer(), pos_integer()) :: :ok | {:error, :already_open | String.t()}
  def open_lot(lot_id, reserve_cents, min_increment_cents)
      when is_binary(lot_id) and is_integer(reserve_cents) and reserve_cents > 0 and
             is_integer(min_increment_cents) and min_increment_cents > 0 do
    GenServer.call(__MODULE__, {:open_lot, lot_id, reserve_cents, min_increment_cents})
  end

  def open_lot(_lot_id, _res, _inc), do: {:error, "invalid lot parameters"}

  @doc """
  Places a bid on `lot_id` for `bidder_id`.
  Returns `{:ok, bid}` or `{:error, reason}`.
  """
  @spec place_bid(lot_id(), bidder_id(), pos_integer()) ::
          {:ok, bid()} | {:error, atom() | String.t()}
  def place_bid(lot_id, bidder_id, amount_cents)
      when is_binary(lot_id) and is_binary(bidder_id) and
             is_integer(amount_cents) and amount_cents > 0 do
    GenServer.call(__MODULE__, {:place_bid, lot_id, bidder_id, amount_cents})
  end

  @doc """
  Closes bidding on a lot and returns the winning bid, if any.
  """
  @spec close_lot(lot_id()) ::
          {:ok, {:sold, bid()} | :unsold} | {:error, :not_found | :already_closed}
  def close_lot(lot_id) when is_binary(lot_id) do
    GenServer.call(__MODULE__, {:close_lot, lot_id})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{lots: %{}}}

  @impl GenServer
  def handle_call({:open_lot, lot_id, reserve_cents, min_increment_cents}, _from, state) do
    if Map.has_key?(state.lots, lot_id) do
      {:reply, {:error, :already_open}, state}
    else
      lot = %{lot_id: lot_id, reserve_cents: reserve_cents, min_increment_cents: min_increment_cents, leading_bid: nil, bid_count: 0, open: true}
      {:reply, :ok, %{state | lots: Map.put(state.lots, lot_id, lot)}}
    end
  end

  @impl GenServer
  def handle_call({:place_bid, lot_id, bidder_id, amount_cents}, _from, state) do
    case Map.fetch(state.lots, lot_id) do
      :error ->
        {:reply, {:error, :lot_not_found}, state}

      {:ok, %{open: false}} ->
        {:reply, {:error, :lot_closed}, state}

      {:ok, lot} ->
        case validate_bid(lot, bidder_id, amount_cents) do
          :ok ->
            bid = %{bidder_id: bidder_id, amount_cents: amount_cents, placed_at: DateTime.utc_now()}
            updated_lot = %{lot | leading_bid: bid, bid_count: lot.bid_count + 1}
            {:reply, {:ok, bid}, %{state | lots: Map.put(state.lots, lot_id, updated_lot)}}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:close_lot, lot_id}, _from, state) do
    case Map.fetch(state.lots, lot_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{open: false}} ->
        {:reply, {:error, :already_closed}, state}

      {:ok, lot} ->
        updated_lot = %{lot | open: false}
        new_state = %{state | lots: Map.put(state.lots, lot_id, updated_lot)}
        outcome = determine_outcome(lot)
        {:reply, {:ok, outcome}, new_state}
    end
  end

  defp validate_bid(lot, bidder_id, amount_cents) do
    min_required = minimum_required_bid(lot)

    cond do
      match?(%{bidder_id: ^bidder_id}, lot.leading_bid) ->
        {:error, :already_leading_bidder}

      amount_cents < min_required ->
        {:error, {:below_minimum, min_required}}

      true ->
        :ok
    end
  end

  defp minimum_required_bid(%{leading_bid: nil, reserve_cents: reserve}), do: reserve

  defp minimum_required_bid(%{leading_bid: %{amount_cents: top}, min_increment_cents: inc}) do
    top + inc
  end

  defp determine_outcome(%{leading_bid: nil}), do: :unsold
  defp determine_outcome(%{leading_bid: bid, reserve_cents: reserve}) when bid.amount_cents >= reserve, do: {:sold, bid}
  defp determine_outcome(_lot), do: :unsold
end
```
