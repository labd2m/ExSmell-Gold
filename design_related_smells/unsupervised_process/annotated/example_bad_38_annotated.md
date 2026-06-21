# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `AuctionProcess.start/1`
- **Affected function(s):** `AuctionProcess.start/1`, `AuctionHouse.open/1`
- **Short explanation:** Each live auction runs as its own `GenServer` responsible for bid validation, countdown timers, and winner determination. Starting these with `GenServer.start/3` means a crash during an active auction silently discards all bids and state with no recovery, no winner notification, and no refunds.

```elixir
defmodule AuctionProcess do
  use GenServer

  @moduledoc """
  Manages the lifecycle of a single live auction including bid acceptance,
  countdown extension, reserve price enforcement, and winner resolution.
  """

  @extension_seconds 30
  @min_bid_increment_percent 0.05

  defstruct [
    :auction_id,
    :item_id,
    :seller_id,
    :reserve_price,
    :start_price,
    :current_bid,
    :current_bidder,
    :ends_at,
    :status,
    bids: []
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because each auction is a time-sensitive stateful
  # process started via `GenServer.start/3` with no supervisor. Auction processes
  # hold financial state (bids, reserve prices, current winners). A crash silently
  # terminates the auction with no winner determined, no refunds triggered, and
  # no possibility of automatic restart or state recovery.
  def start(%{auction_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end
  # VALIDATION: SMELL END

  def place_bid(auction_id, bidder_id, amount) do
    GenServer.call(via(auction_id), {:bid, bidder_id, amount})
  end

  def close(auction_id) do
    GenServer.call(via(auction_id), :close)
  end

  def status(auction_id) do
    GenServer.call(via(auction_id), :status)
  end

  def bid_history(auction_id) do
    GenServer.call(via(auction_id), :history)
  end

  defp via(id), do: {:via, Registry, {AuctionRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{auction_id: id, item_id: item, seller_id: seller, reserve_price: reserve, start_price: start, duration_seconds: duration}) do
    ends_at = DateTime.add(DateTime.utc_now(), duration, :second)

    state = %__MODULE__{
      auction_id: id,
      item_id: item,
      seller_id: seller,
      reserve_price: Decimal.new(to_string(reserve)),
      start_price: Decimal.new(to_string(start)),
      current_bid: Decimal.new(to_string(start)),
      current_bidder: nil,
      ends_at: ends_at,
      status: :open
    }

    schedule_close(duration * 1_000)
    {:ok, state}
  end

  @impl true
  def handle_call({:bid, bidder_id, amount}, _from, %{status: :open} = state) do
    amount_dec = Decimal.new(to_string(amount))
    min_bid = Decimal.mult(state.current_bid, Decimal.new(to_string(1 + @min_bid_increment_percent)))

    cond do
      Decimal.compare(amount_dec, min_bid) == :lt ->
        {:reply, {:error, {:below_minimum, min_bid}}, state}

      true ->
        bid = %{bidder_id: bidder_id, amount: amount_dec, placed_at: DateTime.utc_now()}
        seconds_left = DateTime.diff(state.ends_at, DateTime.utc_now(), :second)

        ends_at =
          if seconds_left < @extension_seconds do
            extended = DateTime.add(DateTime.utc_now(), @extension_seconds, :second)
            schedule_close(@extension_seconds * 1_000)
            extended
          else
            state.ends_at
          end

        updated = %{state |
          current_bid: amount_dec,
          current_bidder: bidder_id,
          ends_at: ends_at,
          bids: [bid | state.bids]
        }

        {:reply, {:ok, amount_dec}, updated}
    end
  end

  def handle_call({:bid, _bidder_id, _amount}, _from, state) do
    {:reply, {:error, {:auction_not_open, state.status}}, state}
  end

  def handle_call(:close, _from, state) do
    {result, new_state} = resolve_auction(state)
    {:reply, result, new_state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, current_bid: state.current_bid, bidder: state.current_bidder, ends_at: state.ends_at}, state}
  end

  def handle_call(:history, _from, state) do
    {:reply, Enum.reverse(state.bids), state}
  end

  @impl true
  def handle_info(:close, state) do
    {_result, new_state} = resolve_auction(state)
    {:noreply, new_state}
  end

  defp resolve_auction(%{status: :open} = state) do
    reserve_met = Decimal.compare(state.current_bid, state.reserve_price) != :lt

    result =
      if state.current_bidder && reserve_met do
        %{winner: state.current_bidder, winning_bid: state.current_bid, reserve_met: true}
      else
        %{winner: nil, winning_bid: state.current_bid, reserve_met: false}
      end

    {{:ok, result}, %{state | status: :closed}}
  end

  defp resolve_auction(state), do: {{:error, :already_closed}, state}

  defp schedule_close(ms) do
    Process.send_after(self(), :close, ms)
  end
end

defmodule AuctionHouse do
  @moduledoc "Public API for creating and managing auctions."

  def open(%{auction_id: _id} = attrs) do
    case AuctionProcess.start(attrs) do
      {:ok, _pid} -> {:ok, attrs.auction_id}
      {:error, {:already_started, _}} -> {:error, :auction_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  def bid(auction_id, bidder_id, amount) do
    AuctionProcess.place_bid(auction_id, bidder_id, amount)
  end
end
```
