```elixir
defmodule Inventory.StockEventConsumer do
  @moduledoc """
  A Broadway-based consumer that processes stock adjustment events from a
  message queue and applies them to the inventory ledger.

  Each message is individually decoded and validated. Batches are applied
  transactionally; idempotency is enforced via each event's `idempotency_key`.
  """

  use Broadway

  alias Broadway.Message
  alias Inventory.{StockLedger, EventBus}

  @type stock_event :: %{
          product_id: String.t(),
          delta: integer(),
          reason: String.t(),
          idempotency_key: String.t()
        }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Broadway.start_link(__MODULE__, pipeline_config(opts))
  end

  @impl Broadway
  def handle_message(_processor, %Message{data: raw} = message, _context) do
    case decode_event(raw) do
      {:ok, event} -> Message.put_data(message, event)
      {:error, reason} -> Message.failed(message, reason)
    end
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _info, _context) do
    Enum.map(messages, &apply_event/1)
  end

  defp apply_event(%Message{data: event} = message) do
    case StockLedger.apply_adjustment(event.product_id, event.delta, event.idempotency_key) do
      {:ok, entry} ->
        publish_adjusted_event(event, entry)
        message

      {:error, :duplicate_entry} ->
        message

      {:error, reason} ->
        Message.failed(message, reason)
    end
  end

  defp decode_event(raw) when is_binary(raw) do
    with {:ok, map} <- Jason.decode(raw, keys: :atoms),
         :ok <- validate_required_fields(map) do
      {:ok, map}
    else
      {:error, reason} -> {:error, {:decode_failed, reason}}
      :missing_fields -> {:error, :missing_required_fields}
    end
  end

  defp decode_event(_raw), do: {:error, :invalid_message_format}

  defp validate_required_fields(%{product_id: _, delta: _, reason: _, idempotency_key: _}),
    do: :ok

  defp validate_required_fields(_), do: :missing_fields

  defp publish_adjusted_event(event, entry) do
    EventBus.publish(:inventory, :stock_adjusted, %{
      product_id: event.product_id,
      delta: event.delta,
      reason: event.reason,
      ledger_entry_id: entry.id,
      adjusted_at: DateTime.utc_now()
    })
  end

  defp pipeline_config(opts) do
    [
      name: Keyword.get(opts, :name, __MODULE__),
      producer: [
        module: Keyword.fetch!(opts, :producer),
        concurrency: Keyword.get(opts, :producer_concurrency, 1)
      ],
      processors: [
        default: [concurrency: Keyword.get(opts, :processor_concurrency, 10)]
      ],
      batchers: [
        default: [
          batch_size: Keyword.get(opts, :batch_size, 50),
          batch_timeout: Keyword.get(opts, :batch_timeout_ms, 2_000),
          concurrency: Keyword.get(opts, :batcher_concurrency, 3)
        ]
      ]
    ]
  end
end
```
