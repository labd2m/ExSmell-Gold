```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications across multiple delivery channels (email, SMS, push).
  Each channel is independently configurable at call time, enabling the same
  dispatcher to serve different delivery strategies without global config coupling.
  """

  alias Notifications.Channels.{Email, SMS, Push}
  alias Notifications.{DeliveryResult, Message}

  @type channel :: :email | :sms | :push
  @type channel_config :: %{required(:channel) => channel(), optional(atom()) => term()}
  @type dispatch_opts :: [channels: [channel_config()], async: boolean()]

  @doc """
  Dispatches `message` via all channels listed in `opts[:channels]`.

  When `async: true` is set, each delivery is executed in a supervised Task.
  Returns a list of `DeliveryResult` structs in channel order.
  """
  @spec dispatch(Message.t(), dispatch_opts()) :: [DeliveryResult.t()]
  def dispatch(%Message{} = message, opts \\ []) do
    channels = Keyword.get(opts, :channels, [])
    async = Keyword.get(opts, :async, false)

    if async do
      dispatch_async(message, channels)
    else
      dispatch_sync(message, channels)
    end
  end

  # ---------------------------------------------------------------------------
  # Sync and async dispatch strategies
  # ---------------------------------------------------------------------------

  @spec dispatch_sync(Message.t(), [channel_config()]) :: [DeliveryResult.t()]
  defp dispatch_sync(message, channels) do
    Enum.map(channels, fn config -> send_via(message, config) end)
  end

  @spec dispatch_async(Message.t(), [channel_config()]) :: [DeliveryResult.t()]
  defp dispatch_async(message, channels) do
    channels
    |> Enum.map(fn config ->
      Task.Supervisor.async(Notifications.TaskSupervisor, fn -> send_via(message, config) end)
    end)
    |> Task.await_many(10_000)
  end

  @spec send_via(Message.t(), channel_config()) :: DeliveryResult.t()
  defp send_via(message, %{channel: :email} = config) do
    deliver(:email, fn -> Email.send(message, config) end)
  end

  defp send_via(message, %{channel: :sms} = config) do
    deliver(:sms, fn -> SMS.send(message, config) end)
  end

  defp send_via(message, %{channel: :push} = config) do
    deliver(:push, fn -> Push.send(message, config) end)
  end

  defp send_via(_message, %{channel: unsupported}) do
    %DeliveryResult{channel: unsupported, status: :error, reason: :unsupported_channel}
  end

  @spec deliver(channel(), (-> {:ok, term()} | {:error, term()})) :: DeliveryResult.t()
  defp deliver(channel, send_fn) do
    case send_fn.() do
      {:ok, provider_id} ->
        %DeliveryResult{channel: channel, status: :delivered, provider_id: provider_id}

      {:error, reason} ->
        %DeliveryResult{channel: channel, status: :error, reason: reason}
    end
  end
end

defmodule Notifications.Message do
  @moduledoc "Represents a notification message to be dispatched."

  @enforce_keys [:recipient_id, :subject, :body]
  defstruct [:recipient_id, :subject, :body, metadata: %{}]

  @type t :: %__MODULE__{
          recipient_id: String.t(),
          subject: String.t(),
          body: String.t(),
          metadata: map()
        }
end

defmodule Notifications.DeliveryResult do
  @moduledoc "Captures the outcome of a single channel delivery attempt."

  defstruct [:channel, :status, :provider_id, :reason]

  @type t :: %__MODULE__{
          channel: atom(),
          status: :delivered | :error,
          provider_id: String.t() | nil,
          reason: term()
        }
end
```
