```elixir
defmodule Auction.Room do
  use GenServer

  @moduledoc """
  Manages a single live auction room. Tracks active bids, enforces
  bid increment rules, manages a countdown timer, and broadcasts
  real-time updates to connected bidders.
  """

  @closing_extension_seconds 30
  @min_bid_increment_cents 100

  defstruct [
    :auction_id,
    :item,
    :reserve_price_cents,
    :current_bid_cents,
    :current_bidder,
    :bid_history,
    :bidders,
    :status,
    :ends_at,
    :extension_count
  ]

  def open(attrs) do
    state = %__MODULE__{
      auction_id: attrs.id,
      item: attrs.item,
      reserve_price_cents: attrs.reserve_price_cents,
      current_bid_cents: attrs[:starting_bid_cents] || 0,
      current_bidder: nil,
      bid_history: [],
      bidders: MapSet.new(),
      status: :open,
      ends_at: attrs.ends_at,
      extension_count: 0
    }

    GenServer.start(__MODULE__, state, name: via_name(attrs.id))
  end

  @doc "Places a bid on behalf of a bidder."
  def place_bid(auction_id, bidder_id, amount_cents) do
    GenServer.call(via_name(auction_id), {:bid, bidder_id, amount_cents})
  end

  @doc "Returns the current auction state snapshot."
  def snapshot(auction_id) do
    GenServer.call(via_name(auction_id), :snapshot)
  end

  @doc "Joins the auction as an observer/bidder."
  def join(auction_id, bidder_id) do
    GenServer.cast(via_name(auction_id), {:join, bidder_id})
  end

  @doc "Leaves the auction room."
  def leave(auction_id, bidder_id) do
    GenServer.cast(via_name(auction_id), {:leave, bidder_id})
  end

  @doc "Closes the auction early (admin action)."
  def close(auction_id) do
    GenServer.cast(via_name(auction_id), :close)
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_close(state.ends_at)
    {:ok, state}
  end

  @impl true
  def handle_call({:bid, _bidder_id, _amount}, _from, %{status: status} = state)
      when status != :open do
    {:reply, {:error, :auction_not_open}, state}
  end

  def handle_call({:bid, bidder_id, amount_cents}, _from, state) do
    min_valid = state.current_bid_cents + @min_bid_increment_cents

    cond do
      amount_cents < min_valid ->
        {:reply, {:error, {:below_minimum, min_valid}}, state}

      true ->
        bid = %{
          bidder_id: bidder_id,
          amount_cents: amount_cents,
          placed_at: DateTime.utc_now()
        }

        near_close = DateTime.diff(state.ends_at, DateTime.utc_now(), :second) <= @closing_extension_seconds

        {new_ends_at, extension_count} =
          if near_close do
            {DateTime.add(state.ends_at, @closing_extension_seconds, :second),
             state.extension_count + 1}
          else
            {state.ends_at, state.extension_count}
          end

        new_state = %{
          state
          | current_bid_cents: amount_cents,
            current_bidder: bidder_id,
            bid_history: [bid | state.bid_history],
            ends_at: new_ends_at,
            extension_count: extension_count
        }

        broadcast_update(new_state)
        {:reply, {:ok, bid}, new_state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snap = %{
      auction_id: state.auction_id,
      item: state.item,
      status: state.status,
      current_bid_cents: state.current_bid_cents,
      current_bidder: state.current_bidder,
      reserve_met: state.current_bid_cents >= state.reserve_price_cents,
      bidder_count: MapSet.size(state.bidders),
      bid_count: length(state.bid_history),
      ends_at: state.ends_at,
      extension_count: state.extension_count
    }

    {:reply, snap, state}
  end

  @impl true
  def handle_cast({:join, bidder_id}, state) do
    {:noreply, %{state | bidders: MapSet.put(state.bidders, bidder_id)}}
  end

  def handle_cast({:leave, bidder_id}, state) do
    {:noreply, %{state | bidders: MapSet.delete(state.bidders, bidder_id)}}
  end

  def handle_cast(:close, state) do
    final_state = finalize_auction(state)
    {:noreply, final_state}
  end

  @impl true
  def handle_info(:close, state) do
    final_state = finalize_auction(state)
    {:noreply, final_state}
  end

  defp finalize_auction(state) do
    result =
      if state.current_bid_cents >= state.reserve_price_cents and not is_nil(state.current_bidder) do
        :sold
      else
        :reserve_not_met
      end

    %{state | status: result}
  end

  defp schedule_close(ends_at) do
    ms = max(DateTime.diff(ends_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), :close, ms)
  end

  defp broadcast_update(_state), do: :ok

  defp via_name(auction_id) do
    {:via, Registry, {Auction.Registry, auction_id}}
  end
end
```
