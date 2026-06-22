```elixir
defmodule Projections.OrderSummaryProjector do
  @moduledoc """
  Builds and maintains a denormalised read model for order summaries by
  replaying domain events in order.

  The projector is stateless: it receives events and upserts the read model
  in the configured repository. It can be run as a catch-up process or
  driven by a live event subscription.
  """

  require Logger

  alias Projections.OrderSummaryProjector.{ReadModel, Store}

  alias Events.{
    OrderPlaced,
    OrderItemAdded,
    OrderShipped,
    OrderCancelled,
    OrderRefunded
  }

  @type event ::
          OrderPlaced.t()
          | OrderItemAdded.t()
          | OrderShipped.t()
          | OrderCancelled.t()
          | OrderRefunded.t()

  @doc """
  Applies a single event to the read model store.
  """
  @spec apply_event(event()) :: :ok | {:error, String.t()}
  def apply_event(%OrderPlaced{} = event) do
    summary = %ReadModel{
      order_id: event.order_id,
      customer_id: event.customer_id,
      status: :pending,
      item_count: 0,
      total_cents: 0,
      currency: event.currency,
      placed_at: event.occurred_at
    }

    Store.upsert(summary)
  end

  def apply_event(%OrderItemAdded{} = event) do
    with {:ok, summary} <- Store.fetch(event.order_id) do
      updated = %ReadModel{
        summary
        | item_count: summary.item_count + event.quantity,
          total_cents: summary.total_cents + event.quantity * event.unit_price_cents
      }

      Store.upsert(updated)
    end
  end

  def apply_event(%OrderShipped{} = event) do
    update_status(event.order_id, :shipped, %{
      shipped_at: event.occurred_at,
      tracking_number: event.tracking_number
    })
  end

  def apply_event(%OrderCancelled{} = event) do
    update_status(event.order_id, :cancelled, %{cancelled_at: event.occurred_at})
  end

  def apply_event(%OrderRefunded{} = event) do
    with {:ok, summary} <- Store.fetch(event.order_id) do
      updated = %ReadModel{
        summary
        | status: :refunded,
          refunded_cents: summary.refunded_cents + event.refunded_cents
      }

      Store.upsert(updated)
    end
  end

  def apply_event(unknown_event) do
    Logger.debug("OrderSummaryProjector: skipping unhandled event #{inspect(unknown_event.__struct__)}")
    :ok
  end

  @doc """
  Replays a list of events in order to rebuild the read model from scratch.
  """
  @spec replay([event()]) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def replay(events) when is_list(events) do
    {ok_count, errors} =
      Enum.reduce(events, {0, []}, fn event, {count, errs} ->
        case apply_event(event) do
          :ok -> {count + 1, errs}
          {:error, reason} -> {count, [{event, reason} | errs]}
        end
      end)

    if errors == [] do
      {:ok, ok_count}
    else
      Logger.error("#{length(errors)} events failed during replay")
      {:error, "replay completed with #{length(errors)} failures"}
    end
  end

  defp update_status(order_id, status, fields) do
    with {:ok, summary} <- Store.fetch(order_id) do
      updated = struct(%ReadModel{summary | status: status}, fields)
      Store.upsert(updated)
    end
  end
end

defmodule Projections.OrderSummaryProjector.ReadModel do
  @moduledoc false

  defstruct [
    :order_id, :customer_id, :status, :currency,
    :placed_at, :shipped_at, :cancelled_at,
    :tracking_number,
    item_count: 0, total_cents: 0, refunded_cents: 0
  ]

  @type t :: %__MODULE__{}
end

defmodule Projections.OrderSummaryProjector.Store do
  @moduledoc false

  import Ecto.Query

  alias Projections.Repo
  alias Projections.OrderSummaryProjector.ReadModel

  @spec upsert(ReadModel.t()) :: :ok | {:error, String.t()}
  def upsert(%ReadModel{} = model) do
    record = Map.from_struct(model)
    now = DateTime.utc_now()

    {_count, _} =
      Repo.insert_all("order_summaries", [Map.merge(record, %{inserted_at: now, updated_at: now})],
        on_conflict: {:replace_all_except, [:order_id, :inserted_at]},
        conflict_target: :order_id
      )

    :ok
  rescue
    err -> {:error, Exception.message(err)}
  end

  @spec fetch(String.t()) :: {:ok, ReadModel.t()} | {:error, String.t()}
  def fetch(order_id) when is_binary(order_id) do
    case Repo.get_by(ReadModel, order_id: order_id) do
      nil -> {:error, "order summary not found for #{order_id}"}
      record -> {:ok, record}
    end
  end
end
```
