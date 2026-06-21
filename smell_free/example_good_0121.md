```elixir
defmodule MyApp.Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notification jobs to the appropriate delivery channel
  (email, SMS, or push) based on a typed `Notification` struct. Each channel
  is backed by its own supervised worker, so a failure in one channel does
  not affect the others.

  All dispatch functions return tagged result tuples and never raise, making
  them safe to call inside `with` pipelines in controllers and background jobs.
  """

  alias MyApp.Notifications.{Notification, EmailWorker, SmsWorker, PushWorker}

  @type channel :: :email | :sms | :push
  @type dispatch_result ::
          {:ok, reference()} | {:error, :invalid_recipient} | {:error, term()}

  @doc """
  Dispatches a notification to all channels configured on the struct.
  Returns a map of channel atoms to dispatch results.
  """
  @spec dispatch_all(Notification.t()) :: %{channel() => dispatch_result()}
  def dispatch_all(%Notification{} = notification) do
    notification.channels
    |> Enum.map(fn channel -> {channel, dispatch(notification, channel)} end)
    |> Map.new()
  end

  @doc """
  Dispatches a notification to a single, explicitly specified channel.
  """
  @spec dispatch(Notification.t(), channel()) :: dispatch_result()
  def dispatch(%Notification{} = notification, :email) do
    with :ok <- validate_email(notification.recipient_email) do
      EmailWorker.enqueue(%{
        to: notification.recipient_email,
        subject: notification.subject,
        body: notification.body,
        idempotency_key: notification.id
      })
    end
  end

  def dispatch(%Notification{} = notification, :sms) do
    with :ok <- validate_phone(notification.recipient_phone) do
      SmsWorker.enqueue(%{
        to: notification.recipient_phone,
        message: notification.body,
        idempotency_key: notification.id
      })
    end
  end

  def dispatch(%Notification{} = notification, :push) do
    with :ok <- validate_device_token(notification.device_token) do
      PushWorker.enqueue(%{
        token: notification.device_token,
        title: notification.subject,
        body: notification.body,
        idempotency_key: notification.id
      })
    end
  end

  @spec validate_email(String.t() | nil) :: :ok | {:error, :invalid_recipient}
  defp validate_email(email) when is_binary(email) do
    if String.match?(email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/), do: :ok, else: invalid()
  end

  defp validate_email(_), do: invalid()

  @spec validate_phone(String.t() | nil) :: :ok | {:error, :invalid_recipient}
  defp validate_phone(phone) when is_binary(phone) do
    if String.match?(phone, ~r/\A\+[1-9]\d{6,14}\z/), do: :ok, else: invalid()
  end

  defp validate_phone(_), do: invalid()

  @spec validate_device_token(String.t() | nil) :: :ok | {:error, :invalid_recipient}
  defp validate_device_token(token) when is_binary(token) and byte_size(token) > 0, do: :ok
  defp validate_device_token(_), do: invalid()

  @spec invalid() :: {:error, :invalid_recipient}
  defp invalid, do: {:error, :invalid_recipient}
end

defmodule MyApp.Notifications.Notification do
  @moduledoc "Represents an outbound notification ready for delivery."

  @enforce_keys [:id, :subject, :body, :channels]
  defstruct [
    :id,
    :subject,
    :body,
    :recipient_email,
    :recipient_phone,
    :device_token,
    channels: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          subject: String.t(),
          body: String.t(),
          recipient_email: String.t() | nil,
          recipient_phone: String.t() | nil,
          device_token: String.t() | nil,
          channels: [MyApp.Notifications.Dispatcher.channel()]
        }
end
```
