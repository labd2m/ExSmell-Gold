```elixir
defmodule GameServer.BlackjackTable do
  @moduledoc """
  Stateful GenServer modeling a single Blackjack table session.

  Manages player seating, bet placement, card dealing, and hit requests.
  Each table is identified by a unique ID and registered in the application's
  process registry. Tables are supervised under `GameServer.TableSupervisor`
  and started on demand when a session is requested.
  """
  use GenServer

  alias GameServer.{Deck, Hand}

  @type table_id :: String.t()
  @type player_id :: String.t()
  @type phase :: :waiting | :betting | :dealing | :player_turn | :settled

  @type state :: %{
          table_id: table_id(),
          phase: phase(),
          deck: Deck.t(),
          players: %{optional(player_id()) => Hand.t()},
          bets: %{optional(player_id()) => pos_integer()},
          dealer_hand: Hand.t()
        }

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Starts a table session registered under `table_id`."
  @spec start_link(table_id()) :: GenServer.on_start()
  def start_link(table_id) when is_binary(table_id) do
    GenServer.start_link(__MODULE__, table_id, name: via(table_id))
  end

  @doc "Seats `player_id` at the table when it is in the waiting phase."
  @spec seat_player(table_id(), player_id()) :: :ok | {:error, :table_not_available}
  def seat_player(table_id, player_id) when is_binary(player_id) do
    GenServer.call(via(table_id), {:seat_player, player_id})
  end

  @doc "Records a bet from `player_id` for the upcoming round."
  @spec place_bet(table_id(), player_id(), pos_integer()) ::
          :ok | {:error, :invalid_phase | :invalid_amount}
  def place_bet(table_id, player_id, amount)
      when is_binary(player_id) and is_integer(amount) and amount > 0 do
    GenServer.call(via(table_id), {:place_bet, player_id, amount})
  end

  @doc "Deals opening hands to all seated players and the dealer."
  @spec deal(table_id()) :: :ok | {:error, :invalid_phase}
  def deal(table_id), do: GenServer.call(via(table_id), :deal)

  @doc "Deals one card to `player_id` during the player turn phase."
  @spec hit(table_id(), player_id()) :: {:ok, Hand.t()} | {:error, :invalid_phase | :busted}
  def hit(table_id, player_id) when is_binary(player_id) do
    GenServer.call(via(table_id), {:hit, player_id})
  end

  @doc "Returns the current table snapshot."
  @spec table_state(table_id()) :: state()
  def table_state(table_id), do: GenServer.call(via(table_id), :table_state)

  # ── Server callbacks ──────────────────────────────────────────────────────────

  @impl GenServer
  def init(table_id) do
    {:ok, %{table_id: table_id, phase: :waiting, deck: Deck.shuffled(),
            players: %{}, bets: %{}, dealer_hand: Hand.empty()}}
  end

  @impl GenServer
  def handle_call({:seat_player, player_id}, _from, %{phase: :waiting} = state) do
    updated = %{state | players: Map.put(state.players, player_id, Hand.empty()), phase: :betting}
    {:reply, :ok, updated}
  end

  def handle_call({:seat_player, _}, _from, state),
    do: {:reply, {:error, :table_not_available}, state}

  def handle_call({:place_bet, player_id, amount}, _from, %{phase: :betting} = state) do
    {:reply, :ok, %{state | bets: Map.put(state.bets, player_id, amount)}}
  end

  def handle_call({:place_bet, _, _}, _from, state),
    do: {:reply, {:error, :invalid_phase}, state}

  def handle_call(:deal, _from, %{phase: :betting} = state) do
    {:reply, :ok, state |> deal_opening_hands() |> Map.put(:phase, :player_turn)}
  end

  def handle_call(:deal, _from, state), do: {:reply, {:error, :invalid_phase}, state}

  def handle_call({:hit, player_id}, _from, %{phase: :player_turn} = state) do
    {card, new_deck} = Deck.draw(state.deck)
    updated_hand = Hand.add_card(state.players[player_id], card)
    new_state = %{state | players: Map.put(state.players, player_id, updated_hand), deck: new_deck}

    if Hand.busted?(updated_hand) do
      {:reply, {:error, :busted}, new_state}
    else
      {:reply, {:ok, updated_hand}, new_state}
    end
  end

  def handle_call({:hit, _}, _from, state), do: {:reply, {:error, :invalid_phase}, state}
  def handle_call(:table_state, _from, state), do: {:reply, state, state}

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp deal_opening_hands(state) do
    player_count = map_size(state.players)
    {cards, new_deck} = Deck.draw_many(state.deck, player_count * 2 + 2)
    {player_cards, dealer_cards} = Enum.split(cards, player_count * 2)

    player_hands =
      state.players
      |> Map.keys()
      |> Enum.zip(Enum.chunk_every(player_cards, 2))
      |> Map.new(fn {id, two_cards} -> {id, Hand.from_cards(two_cards)} end)

    %{state | players: player_hands, dealer_hand: Hand.from_cards(dealer_cards), deck: new_deck}
  end

  defp via(table_id), do: {:via, Registry, {GameServer.Registry, table_id}}
end
```
