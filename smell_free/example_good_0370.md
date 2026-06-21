```elixir
defmodule Events.SourcingAggregate do
  @moduledoc """
  Base module for building event-sourced aggregates. Provides `apply/2`
  dispatch, stream reconstitution, and snapshot-based loading. Each
  aggregate module implements `handle_command/2` and `apply_event/2`
  callbacks. State is never mutated in place; every event application
  returns a new state map.
  """

  @callback initial_state() :: map()
  @callback handle_command(state :: map(), command :: map()) ::
              {:ok, [map()]} | {:error, term()}
  @callback apply_event(state :: map(), event :: map()) :: map()

  @type stream_id :: String.t()
  @type event :: %{type: String.t(), data: map(), version: pos_integer()}

  @doc "Reconstitutes aggregate state by replaying a list of stored events."
  @spec reconstitute(module(), [event()]) :: map()
  def reconstitute(module, events) when is_atom(module) and is_list(events) do
    Enum.reduce(events, module.initial_state(), fn event, state ->
      module.apply_event(state, event)
    end)
  end

  @doc """
  Executes `command` against the aggregate `module` reconstituted from
  `events`. Returns the new events produced and the resulting state.
  """
  @spec execute(module(), [event()], map()) ::
          {:ok, %{new_events: [map()], state: map()}} | {:error, term()}
  def execute(module, events, command)
      when is_atom(module) and is_list(events) and is_map(command) do
    state = reconstitute(module, events)
    next_version = length(events) + 1

    case module.handle_command(state, command) do
      {:ok, new_events} ->
        versioned = stamp_events(new_events, next_version)
        new_state = Enum.reduce(versioned, state, &module.apply_event(&2, &1))
        {:ok, %{new_events: versioned, state: new_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Applies a single event to `state` via the module callback."
  @spec apply(module(), map(), event()) :: map()
  def apply(module, state, event) when is_atom(module) and is_map(state) and is_map(event) do
    module.apply_event(state, event)
  end

  defp stamp_events(events, start_version) do
    events
    |> Enum.with_index(start_version)
    |> Enum.map(fn {event, version} ->
      Map.merge(event, %{version: version, occurred_at: DateTime.to_iso8601(DateTime.utc_now())})
    end)
  end
end

defmodule Events.BankAccount do
  @moduledoc "Event-sourced bank account aggregate using `Events.SourcingAggregate`."

  @behaviour Events.SourcingAggregate

  @impl Events.SourcingAggregate
  def initial_state, do: %{id: nil, balance_cents: 0, open: false}

  @impl Events.SourcingAggregate
  def handle_command(%{open: false}, %{type: "open_account", data: %{id: id}}),
    do: {:ok, [%{type: "account_opened", data: %{id: id}}]}

  def handle_command(%{open: true, balance_cents: bal}, %{type: "deposit", data: %{amount: a}})
      when is_integer(a) and a > 0,
    do: {:ok, [%{type: "funds_deposited", data: %{amount: a, balance_after: bal + a}}]}

  def handle_command(%{open: true, balance_cents: bal}, %{type: "withdraw", data: %{amount: a}})
      when is_integer(a) and a > 0 and bal >= a,
    do: {:ok, [%{type: "funds_withdrawn", data: %{amount: a, balance_after: bal - a}}]}

  def handle_command(%{open: true, balance_cents: bal}, %{type: "withdraw", data: %{amount: a}})
      when is_integer(a) and a > 0 and bal < a,
    do: {:error, :insufficient_funds}

  def handle_command(_state, command), do: {:error, {:unhandled_command, command.type}}

  @impl Events.SourcingAggregate
  def apply_event(state, %{type: "account_opened", data: %{id: id}}),
    do: %{state | id: id, open: true}

  def apply_event(state, %{type: "funds_deposited", data: %{balance_after: bal}}),
    do: %{state | balance_cents: bal}

  def apply_event(state, %{type: "funds_withdrawn", data: %{balance_after: bal}}),
    do: %{state | balance_cents: bal}

  def apply_event(state, _event), do: state
end
```
