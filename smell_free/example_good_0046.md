```elixir
defmodule Auction.Room do
  @moduledoc """
  Models a live auction room as a GenServer. Maintains bidding history,
  enforces minimum bid increments and reserve price rules, tracks the
  current leader, and closes the auction automatically after its duration.
  """

  use GenServer

  require Logger

  @type bid :: %{bidder_id: String.t(), amount_cents: pos_integer(), placed_at: DateTime.t()}
  @type status :: :open | :closed
  @type state :: %{
          room_id: String.t(),
          item_id: String.t(),
          reserve_cents: pos_integer(),
          min_increment_cents: pos_integer(),
          bids: [bid()],
          status: status()
        }

  @default_duration_ms :timer.minutes(10)

  @doc "Starts an auction room linked to the calling supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  @doc """
  Places a bid for `bidder_id` at `amount_cents`. Returns the accepted bid
  or a typed error when the auction is closed or the bid is below the minimum.
  """
  @spec place_bid(String.t(), String.t(), pos_integer()) ::
          {:ok, bid()} | {:error, :auction_closed | :bid_too_low}
  def place_bid(room_id, bidder_id, amount_cents)
      when is_binary(room_id) and is_binary(bidder_id) and is_integer(amount_cents) do
    GenServer.call(via(room_id), {:place_bid, bidder_id, amount_cents})
  end

  @doc "Returns a summary map of current auction state."
  @spec summary(String.t()) :: map()
  def summary(room_id) when is_binary(room_id) do
    GenServer.call(via(room_id), :summary)
  end

  @impl GenServer
  def init(opts) do
    duration = Keyword.get(opts, :duration_ms, @default_duration_ms)
    Process.send_after(self(), :close, duration)

    {:ok,
     %{
       room_id: Keyword.fetch!(opts, :room_id),
       item_id: Keyword.fetch!(opts, :item_id),
       reserve_cents: Keyword.fetch!(opts, :reserve_cents),
       min_increment_cents: Keyword.get(opts, :min_increment_cents, 100),
       bids: [],
       status: :open
     }}
  end

  @impl GenServer
  def handle_call({:place_bid, _bidder, _amount}, _from, %{status: :closed} = state) do
    {:reply, {:error, :auction_closed}, state}
  end

  def handle_call({:place_bid, bidder_id, amount_cents}, _from, state) do
    case validate_bid(amount_cents, state) do
      :ok ->
        bid = %{bidder_id: bidder_id, amount_cents: amount_cents, placed_at: DateTime.utc_now()}
        {:reply, {:ok, bid}, %{state | bids: [bid | state.bids]}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:summary, _from, state) do
    reply = %{
      room_id: state.room_id,
      item_id: state.item_id,
      status: state.status,
      bid_count: length(state.bids),
      leading_bid: List.first(state.bids)
    }

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(:close, state) do
    Logger.info("[Auction.Room] #{state.room_id} closed with #{length(state.bids)} bid(s)")
    {:noreply, %{state | status: :closed}}
  end

  defp validate_bid(amount, %{bids: [], reserve_cents: reserve}) do
    if amount >= reserve, do: :ok, else: {:error, :bid_too_low}
  end

  defp validate_bid(amount, %{bids: [top | _], min_increment_cents: inc}) do
    if amount >= top.amount_cents + inc, do: :ok, else: {:error, :bid_too_low}
  end

  defp via(room_id), do: {:via, Registry, {Auction.Registry, room_id}}
end
```
