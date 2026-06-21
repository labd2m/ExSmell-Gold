```elixir
defmodule Billing.SubscriptionFsm do
  @moduledoc """
  A GenServer that models a subscription's lifecycle as a finite state machine.

  Valid states: `:trialing` → `:active` → `:past_due` → `:cancelled`.
  Transitions that violate the state graph are rejected with an error tuple,
  ensuring no invalid state can be persisted to the database.
  """

  use GenServer

  require Logger

  alias Billing.{Repo, Subscription}

  @type subscription_id :: pos_integer()
  @type state_name :: :trialing | :active | :past_due | :cancelled
  @type transition_result :: {:ok, state_name()} | {:error, :invalid_transition | term()}

  @allowed_transitions %{
    trialing: [:active, :cancelled],
    active: [:past_due, :cancelled],
    past_due: [:active, :cancelled],
    cancelled: []
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)
    GenServer.start_link(__MODULE__, opts, name: via(subscription_id))
  end

  @doc "Transitions the subscription to `target_state` if the transition is valid."
  @spec transition(subscription_id(), state_name()) :: transition_result()
  def transition(subscription_id, target_state) when is_atom(target_state) do
    GenServer.call(via(subscription_id), {:transition, target_state})
  end

  @doc "Returns the current state name of the subscription."
  @spec current_state(subscription_id()) :: {:ok, state_name()} | {:error, :not_found}
  def current_state(subscription_id) do
    case Registry.lookup(Billing.SubscriptionRegistry, subscription_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :current_state)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)

    case Repo.get(Subscription, subscription_id) do
      nil -> {:stop, :subscription_not_found}
      sub -> {:ok, %{subscription: sub, current: sub.state}}
    end
  end

  @impl GenServer
  def handle_call({:transition, target}, _from, %{current: current} = state) do
    allowed = Map.fetch!(@allowed_transitions, current)

    if target in allowed do
      case persist_transition(state.subscription, target) do
        {:ok, updated_sub} ->
          {:reply, {:ok, target}, %{state | subscription: updated_sub, current: target}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      Logger.warning("[SubscriptionFsm] Invalid transition", from: current, to: target)
      {:reply, {:error, :invalid_transition}, state}
    end
  end

  @impl GenServer
  def handle_call(:current_state, _from, %{current: current} = state) do
    {:reply, current, state}
  end

  defp persist_transition(subscription, new_state) do
    subscription
    |> Subscription.state_changeset(%{state: new_state, state_changed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp via(subscription_id) do
    {:via, Registry, {Billing.SubscriptionRegistry, subscription_id}}
  end
end
```
