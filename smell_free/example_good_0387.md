```elixir
defmodule Messaging.Outbox do
  @moduledoc """
  Implements the transactional outbox pattern. Domain operations that need
  to emit external messages (e.g., emails, webhooks, third-party API calls)
  insert an `OutboxMessage` record within the same database transaction as
  their state change. A separate Oban worker reliably picks up and dispatches
  each message, guaranteeing at-least-once delivery without distributed
  transactions or two-phase commits.
  """

  alias Messaging.{OutboxMessage, Repo}
  alias Ecto.Multi

  @type message_type :: binary()
  @type message_payload :: map()

  @doc """
  Appends an outbox message entry to an existing `Ecto.Multi` pipeline.
  The message is persisted atomically alongside the business operation.
  The Oban job is inserted after the transaction commits via `Oban.insert/1`.

  ## Example

      Multi.new()
      |> Multi.insert(:order, Order.changeset(%Order{}, attrs))
      |> Outbox.append(:order_placed_email, "order.placed", fn %{order: order} ->
           %{order_id: order.id, customer_id: order.customer_id}
         end)
      |> Repo.transaction()
  """
  @spec append(Multi.t(), atom(), message_type(), (map() -> message_payload())) :: Multi.t()
  def append(%Multi{} = multi, step_name, message_type, payload_fn)
      when is_atom(step_name) and is_binary(message_type) and is_function(payload_fn, 1) do
    Multi.insert(multi, step_name, fn changes ->
      payload = payload_fn.(changes)
      OutboxMessage.changeset(%OutboxMessage{}, %{type: message_type, payload: payload})
    end)
  end

  @doc """
  Inserts a standalone outbox message outside of an existing `Multi`.
  Wraps the insert in its own transaction.
  """
  @spec enqueue(message_type(), message_payload()) :: {:ok, OutboxMessage.t()} | {:error, term()}
  def enqueue(message_type, payload) when is_binary(message_type) and is_map(payload) do
    %OutboxMessage{}
    |> OutboxMessage.changeset(%{type: message_type, payload: payload})
    |> Repo.insert()
  end
end

defmodule Messaging.OutboxDispatcher do
  @moduledoc """
  An Oban worker that processes a single `OutboxMessage`. The dispatcher
  routes each message to the appropriate handler module based on the
  message type, marks the message as delivered on success, and leaves
  it in a `:failed` state (for manual inspection) after exhausting retries.
  """

  use Oban.Worker, queue: :outbox, max_attempts: 10

  alias Messaging.{OutboxMessage, Repo}

  require Logger

  @handlers %{
    "order.placed" => Messaging.Handlers.OrderPlaced,
    "user.registered" => Messaging.Handlers.UserRegistered,
    "invoice.generated" => Messaging.Handlers.InvoiceGenerated
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    with {:ok, message} <- fetch_pending(message_id),
         {:ok, handler} <- resolve_handler(message.type),
         :ok <- handler.handle(message.payload) do
      mark_delivered(message)
      :ok
    else
      {:error, :already_processed} ->
        :ok

      {:error, :no_handler} ->
        Logger.error("No handler for outbox message type",
          message_id: message_id,
          type: fetch_type(message_id)
        )
        {:error, :no_handler}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_pending(message_id) do
    case Repo.get(OutboxMessage, message_id) do
      %OutboxMessage{status: :pending} = msg -> {:ok, msg}
      %OutboxMessage{status: :delivered} -> {:error, :already_processed}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_handler(type) do
    case Map.get(@handlers, type) do
      nil -> {:error, :no_handler}
      handler -> {:ok, handler}
    end
  end

  defp mark_delivered(%OutboxMessage{} = message) do
    message
    |> OutboxMessage.delivered_changeset()
    |> Repo.update()
  end

  defp fetch_type(message_id) do
    case Repo.get(OutboxMessage, message_id) do
      %OutboxMessage{type: type} -> type
      nil -> "unknown"
    end
  end
end
```
