```elixir
defmodule Notifications.Message do
  @moduledoc """
  An immutable value object representing an outbound notification.
  """

  @enforce_keys [:id, :type, :subject, :body, :recipient_id]
  defstruct [:id, :type, :subject, :body, :recipient_id, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          subject: String.t(),
          body: String.t(),
          recipient_id: integer(),
          metadata: map() | nil
        }

  @spec new(atom(), String.t(), String.t(), integer(), map()) :: t()
  def new(type, subject, body, recipient_id, metadata \\ %{})
      when is_atom(type) and is_binary(subject) and is_binary(body) and is_integer(recipient_id) do
    %__MODULE__{
      id: generate_id(),
      type: type,
      subject: subject,
      body: body,
      recipient_id: recipient_id,
      metadata: metadata
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end

defmodule Notifications.Preference do
  @moduledoc """
  Represents a user's channel opt-in preferences for notifications.
  """

  @enforce_keys [:user_id]
  defstruct [:user_id, email: true, sms: false, push: false]

  @type t :: %__MODULE__{
          user_id: integer(),
          email: boolean(),
          sms: boolean(),
          push: boolean()
        }

  @spec new(integer(), keyword()) :: t()
  def new(user_id, opts \\ []) when is_integer(user_id) do
    %__MODULE__{
      user_id: user_id,
      email: Keyword.get(opts, :email, true),
      sms: Keyword.get(opts, :sms, false),
      push: Keyword.get(opts, :push, false)
    }
  end

  @spec enabled_channels(t()) :: list(:email | :sms | :push)
  def enabled_channels(%__MODULE__{} = pref) do
    [:email, :sms, :push]
    |> Enum.filter(fn channel -> Map.get(pref, channel) == true end)
  end
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channels
  based on recipient preferences. Returns per-channel delivery outcomes.
  """

  alias Notifications.{Message, Preference}
  alias Notifications.Channel

  @type delivery_outcome :: {:ok, String.t()} | {:error, atom()}

  @spec dispatch(Message.t(), Preference.t()) :: %{atom() => delivery_outcome()}
  def dispatch(%Message{} = message, %Preference{} = preference) do
    preference
    |> Preference.enabled_channels()
    |> Map.new(fn channel -> {channel, deliver(message, channel)} end)
  end

  @spec dispatch_to_channel(Message.t(), :email | :sms | :push) :: delivery_outcome()
  def dispatch_to_channel(%Message{} = message, channel)
      when channel in [:email, :sms, :push] do
    deliver(message, channel)
  end

  defp deliver(message, :email), do: Channel.Email.send(message)
  defp deliver(message, :sms), do: Channel.SMS.send(message)
  defp deliver(message, :push), do: Channel.Push.send(message)
end
```
