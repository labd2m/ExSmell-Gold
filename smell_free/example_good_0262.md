```elixir
defmodule Notifications.Pipeline do
  @moduledoc """
  A Broadway pipeline that consumes notification jobs from a RabbitMQ queue
  and fans them out to the appropriate delivery channels (email, push, SMS).
  Each message is routed based on its `channel` field. Failed deliveries are
  retried up to the configured maximum before being forwarded to a dead-letter
  queue for manual inspection.
  """

  use Broadway

  alias Broadway.Message
  alias Notifications.{Channels, Dispatcher}

  require Logger

  @max_retries 3

  @doc """
  Starts the pipeline and links it to the calling supervisor. Configures
  producer, processor, and batcher concurrency from application config.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Broadway.start_link(__MODULE__, broadway_config(opts))
  end

  @impl Broadway
  def handle_message(:default, %Message{} = message, _context) do
    with {:ok, payload} <- decode_payload(message.data),
         {:ok, channel} <- resolve_channel(payload),
         :ok <- Dispatcher.deliver(channel, payload) do
      message
    else
      {:error, :unknown_channel} ->
        Message.failed(message, "unknown_channel")

      {:error, reason} ->
        handle_delivery_failure(message, reason)
    end
  end

  @impl Broadway
  def handle_failed(messages, _context) do
    Enum.each(messages, fn msg ->
      Logger.warning("Notification delivery failed",
        reason: msg.status,
        retry_count: retry_count(msg),
        message_id: msg.metadata[:message_id]
      )
    end)

    messages
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp decode_payload(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp resolve_channel(%{"channel" => channel}) when channel in Channels.supported() do
    {:ok, String.to_existing_atom(channel)}
  end

  defp resolve_channel(%{"channel" => _}), do: {:error, :unknown_channel}
  defp resolve_channel(_), do: {:error, :missing_channel}

  defp handle_delivery_failure(message, reason) do
    count = retry_count(message)

    if count < @max_retries do
      Message.failed(message, {:retryable, reason})
    else
      Logger.error("Exhausted retries for notification",
        reason: reason,
        metadata: message.metadata
      )

      Message.failed(message, {:dead_letter, reason})
    end
  end

  defp retry_count(%Message{metadata: %{retry_count: n}}), do: n
  defp retry_count(_message), do: 0

  defp broadway_config(opts) do
    [
      name: __MODULE__,
      producer: [
        module:
          {BroadwayRabbitMQ.Producer,
           queue: Application.fetch_env!(:notifications, :queue_name),
           connection: Application.fetch_env!(:notifications, :amqp_url)},
        concurrency: Keyword.get(opts, :producer_concurrency, 1)
      ],
      processors: [
        default: [concurrency: Keyword.get(opts, :processor_concurrency, 20)]
      ],
      batchers: [
        default: [concurrency: 1, batch_size: 100, batch_timeout: 2_000]
      ]
    ]
  end
end
```
