```elixir
defmodule Notifications.Recipient do
  @moduledoc """
  Represents a notification recipient with their available contact channels.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t() | nil,
          phone: String.t() | nil,
          push_token: String.t() | nil,
          locale: String.t()
        }

  defstruct [:id, :email, :phone, :push_token, locale: "en"]
end

defmodule Notifications.Message do
  @moduledoc """
  A domain value representing a notification to be delivered.
  """

  @type priority :: :critical | :normal | :low

  @type t :: %__MODULE__{
          id: String.t(),
          subject: String.t(),
          body: String.t(),
          priority: priority()
        }

  defstruct [:id, :subject, :body, priority: :normal]
end

defmodule Notifications.ChannelSelector do
  @moduledoc false

  alias Notifications.{Message, Recipient}

  @spec resolve(Message.priority(), Recipient.t()) :: [:email | :sms | :push]
  def resolve(:critical, recipient) do
    [:sms, :email, :push] |> Enum.filter(&channel_available?(&1, recipient))
  end

  def resolve(:normal, recipient) do
    [:push, :email] |> Enum.filter(&channel_available?(&1, recipient))
  end

  def resolve(:low, recipient) do
    [:push] |> Enum.filter(&channel_available?(&1, recipient))
  end

  defp channel_available?(:email, %Recipient{email: v}), do: not is_nil(v)
  defp channel_available?(:sms, %Recipient{phone: v}), do: not is_nil(v)
  defp channel_available?(:push, %Recipient{push_token: v}), do: not is_nil(v)
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel.

  Channel selection is driven by recipient preferences and message priority.
  When a channel fails, the dispatcher advances to the next available
  option in the priority chain rather than surfacing an error immediately.
  All delivery attempts are logged for observability.
  """

  require Logger

  alias Notifications.{ChannelSelector, Message, Recipient}
  alias Notifications.Channels.{Email, Push, Sms}

  @type dispatch_result ::
          {:ok, :delivered, :email | :sms | :push}
          | {:error, :no_channel_available}

  @spec dispatch(Message.t(), Recipient.t()) :: dispatch_result()
  def dispatch(%Message{} = message, %Recipient{} = recipient) do
    channels = ChannelSelector.resolve(message.priority, recipient)

    case channels do
      [] -> {:error, :no_channel_available}
      available -> try_channels(message, recipient, available)
    end
  end

  defp try_channels(_message, _recipient, []) do
    {:error, :no_channel_available}
  end

  defp try_channels(message, recipient, [channel | rest]) do
    case deliver(channel, message, recipient) do
      :ok ->
        Logger.info("Notification delivered",
          message_id: message.id,
          recipient_id: recipient.id,
          channel: channel
        )

        {:ok, :delivered, channel}

      {:error, reason} ->
        Logger.warning("Channel delivery failed, trying next",
          channel: channel,
          reason: inspect(reason)
        )

        try_channels(message, recipient, rest)
    end
  end

  defp deliver(:email, message, recipient), do: Email.send(message, recipient)
  defp deliver(:sms, message, recipient), do: Sms.send(message, recipient)
  defp deliver(:push, message, recipient), do: Push.send(message, recipient)
end
```
