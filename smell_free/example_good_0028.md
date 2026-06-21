```elixir
defmodule Notifier.Dispatcher do
  @moduledoc """
  Routes structured domain events to subscribers via `Phoenix.PubSub`.

  Topic naming is enforced through this module's API to prevent cross-category
  subscriptions. Event payloads are wrapped in a consistent envelope with an
  `occurred_at` timestamp.
  """

  alias Phoenix.PubSub

  @pubsub Notifier.PubSub

  @type category :: :account | :order | :payment | :inventory | :session
  @type event :: %{
          category: category(),
          type: atom(),
          payload: map(),
          occurred_at: DateTime.t()
        }

  @doc """
  Broadcasts a typed event to all subscribers of `category`.
  """
  @spec broadcast(category(), atom(), map()) :: :ok | {:error, term()}
  def broadcast(category, type, payload)
      when is_atom(category) and is_atom(type) and is_map(payload) do
    event = build_event(category, type, payload)
    PubSub.broadcast(@pubsub, topic(category), {:domain_event, event})
  end

  @doc """
  Subscribes the calling process to events from the given category.
  """
  @spec subscribe(category()) :: :ok | {:error, term()}
  def subscribe(category) when is_atom(category) do
    PubSub.subscribe(@pubsub, topic(category))
  end

  @doc "Unsubscribes the calling process from a category's events."
  @spec unsubscribe(category()) :: :ok
  def unsubscribe(category) when is_atom(category) do
    PubSub.unsubscribe(@pubsub, topic(category))
  end

  @doc "Broadcasts the same event to multiple categories."
  @spec broadcast_multi([category()], atom(), map()) :: [:ok | {:error, term()}]
  def broadcast_multi(categories, type, payload) when is_list(categories) do
    Enum.map(categories, &broadcast(&1, type, payload))
  end

  defp build_event(category, type, payload) do
    %{category: category, type: type, payload: payload, occurred_at: DateTime.utc_now()}
  end

  defp topic(category), do: "events:#{category}"
end

defmodule Notifier.AccountEventHandler do
  @moduledoc """
  Processes account-scoped domain events published by `Notifier.Dispatcher`.

  Intended for use inside a supervised GenServer that subscribes during
  `init/1` and delegates incoming messages to `handle_event/1`.
  """

  require Logger

  alias Notifier.Dispatcher

  @type event :: Dispatcher.event()

  @doc "Subscribes the calling process to account events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Dispatcher.subscribe(:account)

  @doc """
  Dispatches a domain event to the appropriate handler clause.

  Should be invoked from `handle_info/2` when `{:domain_event, event}` arrives.
  """
  @spec handle_event(event()) :: :ok
  def handle_event(%{type: :account_created, payload: payload}) do
    Logger.info("[AccountHandler] Account created", id: payload[:id])
    :ok
  end

  def handle_event(%{type: :account_suspended, payload: payload}) do
    Logger.warning("[AccountHandler] Account suspended",
      id: payload[:id],
      reason: payload[:reason]
    )
    :ok
  end

  def handle_event(%{type: :account_reactivated, payload: payload}) do
    Logger.info("[AccountHandler] Account reactivated", id: payload[:id])
    :ok
  end

  def handle_event(%{type: type}) do
    Logger.debug("[AccountHandler] Unhandled event", type: type)
    :ok
  end
end
```
