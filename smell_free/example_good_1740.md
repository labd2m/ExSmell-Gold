**File:** `example_good_1740.md`

```elixir
defmodule Notifications.Message do
  @moduledoc "Represents a notification message targeted at a specific recipient."

  @enforce_keys [:id, :recipient_id, :subject, :body, :channel]
  defstruct [:id, :recipient_id, :subject, :body, :channel, :metadata]

  @type channel :: :email | :sms | :push
  @type t :: %__MODULE__{
          id: String.t(),
          recipient_id: String.t(),
          subject: String.t(),
          body: String.t(),
          channel: channel(),
          metadata: map() | nil
        }
end

defprotocol Notifications.Channel do
  @moduledoc """
  Defines the delivery contract for a notification channel.
  Each channel implementation handles its own transport specifics.
  """

  @doc "Sends the given message via this channel. Returns :ok or {:error, reason}."
  @spec deliver(t(), Notifications.Message.t()) :: :ok | {:error, term()}
  def deliver(channel, message)
end

defmodule Notifications.EmailChannel do
  @moduledoc "Delivers notifications via SMTP email."

  @enforce_keys [:smtp_host, :from_address]
  defstruct [:smtp_host, :from_address, port: 587]

  @type t :: %__MODULE__{
          smtp_host: String.t(),
          from_address: String.t(),
          port: pos_integer()
        }
end

defmodule Notifications.SmsChannel do
  @moduledoc "Delivers notifications via SMS using a configured gateway."

  @enforce_keys [:gateway_url, :sender_number]
  defstruct [:gateway_url, :sender_number, :api_key]

  @type t :: %__MODULE__{
          gateway_url: String.t(),
          sender_number: String.t(),
          api_key: String.t() | nil
        }
end

defmodule Notifications.PushChannel do
  @moduledoc "Delivers notifications via mobile push using a configured FCM/APNS endpoint."

  @enforce_keys [:endpoint_url, :app_id]
  defstruct [:endpoint_url, :app_id, :api_key]

  @type t :: %__MODULE__{
          endpoint_url: String.t(),
          app_id: String.t(),
          api_key: String.t() | nil
        }
end

defimpl Notifications.Channel, for: Notifications.EmailChannel do
  require Logger

  def deliver(%Notifications.EmailChannel{} = config, %Notifications.Message{} = msg) do
    Logger.info("Sending email to recipient=#{msg.recipient_id} subject=#{msg.subject} via #{config.smtp_host}")
    :ok
  end
end

defimpl Notifications.Channel, for: Notifications.SmsChannel do
  require Logger

  def deliver(%Notifications.SmsChannel{} = config, %Notifications.Message{} = msg) do
    Logger.info("Sending SMS to recipient=#{msg.recipient_id} from=#{config.sender_number}")
    :ok
  end
end

defimpl Notifications.Channel, for: Notifications.PushChannel do
  require Logger

  def deliver(%Notifications.PushChannel{} = config, %Notifications.Message{} = msg) do
    Logger.info("Sending push to recipient=#{msg.recipient_id} app=#{config.app_id}")
    :ok
  end
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches a notification message through its designated channel implementation.
  Resolves the channel struct from a registry and delegates to the protocol.
  """

  alias Notifications.{Channel, Message}

  @type channel_registry :: %{Message.channel() => Channel.t()}

  @spec dispatch(Message.t(), channel_registry()) :: :ok | {:error, term()}
  def dispatch(%Message{channel: channel_key} = message, registry) do
    case Map.fetch(registry, channel_key) do
      {:ok, channel} ->
        Channel.deliver(channel, message)

      :error ->
        {:error, {:unconfigured_channel, channel_key}}
    end
  end

  @spec dispatch_all([Message.t()], channel_registry()) :: %{ok: non_neg_integer(), error: non_neg_integer()}
  def dispatch_all(messages, registry) when is_list(messages) do
    Enum.reduce(messages, %{ok: 0, error: 0}, fn msg, acc ->
      case dispatch(msg, registry) do
        :ok -> Map.update!(acc, :ok, &(&1 + 1))
        {:error, _} -> Map.update!(acc, :error, &(&1 + 1))
      end
    end)
  end
end
```
