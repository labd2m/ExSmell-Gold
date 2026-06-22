```elixir
defmodule Notifications.Message do
  @moduledoc """
  A notification payload targeting a specific user across one or more channels.
  """

  @type channel :: :email | :sms | :push

  @type t :: %__MODULE__{
          user_id: String.t(),
          subject: String.t(),
          body: String.t(),
          channels: [channel()]
        }

  defstruct [:user_id, :subject, :body, channels: []]
end

defprotocol Notifications.Adapter do
  @moduledoc """
  Protocol that channel-specific adapters must implement to dispatch
  a notification through their transport.
  """

  @spec deliver(t(), Notifications.Message.t()) :: :ok | {:error, term()}
  def deliver(adapter, message)
end

defmodule Notifications.EmailAdapter do
  defstruct [:from_address, :api_key]

  defimpl Notifications.Adapter do
    def deliver(%{from_address: from, api_key: key}, message) do
      Bamboo.Email.new_email(
        to: message.user_id,
        from: from,
        subject: message.subject,
        text_body: message.body
      )
      |> Bamboo.Mailer.deliver_now(config: [api_key: key])
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

defmodule Notifications.SmsAdapter do
  defstruct [:account_sid, :auth_token, :from_number]

  defimpl Notifications.Adapter do
    def deliver(%{account_sid: sid, auth_token: token, from_number: from}, message) do
      ExTwilio.Message.create(
        to: message.user_id,
        from: from,
        body: message.body,
        account_sid: sid,
        auth_token: token
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

defmodule Notifications.Dispatcher do
  alias Notifications.{Adapter, Message}

  @moduledoc """
  Routes a `Message` to all requested channels using the registered adapters.
  Partial failures are reported individually without aborting remaining channels.
  """

  @type adapter_map :: %{Message.channel() => Adapter.t()}
  @type dispatch_result :: %{channel: Message.channel(), result: :ok | {:error, term()}}

  @spec dispatch(Message.t(), adapter_map()) :: [dispatch_result()]
  def dispatch(%Message{} = message, adapters) when is_map(adapters) do
    message.channels
    |> Enum.filter(&Map.has_key?(adapters, &1))
    |> Enum.map(fn channel ->
      adapter = Map.fetch!(adapters, channel)
      result = Adapter.deliver(adapter, message)
      %{channel: channel, result: result}
    end)
  end

  @spec all_delivered?([dispatch_result()]) :: boolean()
  def all_delivered?(results) when is_list(results) do
    Enum.all?(results, fn %{result: r} -> r == :ok end)
  end
end
```
