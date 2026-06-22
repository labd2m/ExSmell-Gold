```elixir
defmodule Notifications.Delivery.Dispatcher do
  @moduledoc """
  Supervised dispatcher for multi-channel notification delivery.

  Routes notification jobs to channel-specific sender modules based on
  recipient preferences, with per-channel retry supervision.
  """

  use Supervisor

  alias Notifications.Delivery.{EmailSender, SmsSender, PushSender}
  alias Notifications.Queue.JobConsumer

  @type channel :: :email | :sms | :push

  @type notification :: %{
          recipient_id: String.t(),
          channel: channel(),
          template: atom(),
          payload: map()
        }

  @doc """
  Starts the dispatcher supervisor and all channel sender workers.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {EmailSender, concurrency: 10},
      {SmsSender, concurrency: 5},
      {PushSender, concurrency: 20},
      {JobConsumer, dispatcher: __MODULE__}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Dispatches a notification to the appropriate channel sender.

  Returns `{:ok, ref}` with a delivery reference on success, or
  `{:error, :unsupported_channel}` for unknown channel values.
  """
  @spec dispatch(notification()) :: {:ok, reference()} | {:error, :unsupported_channel}
  def dispatch(%{channel: :email} = notification) do
    EmailSender.send(notification)
  end

  def dispatch(%{channel: :sms} = notification) do
    SmsSender.send(notification)
  end

  def dispatch(%{channel: :push} = notification) do
    PushSender.send(notification)
  end

  def dispatch(%{channel: _unknown}) do
    {:error, :unsupported_channel}
  end

  @doc """
  Returns the current delivery status for a previously dispatched notification.
  """
  @spec delivery_status(reference()) ::
          {:ok, :delivered | :pending | :failed} | {:error, :not_found}
  def delivery_status(ref) when is_reference(ref) do
    case :ets.lookup(:notification_delivery_status, ref) do
      [{^ref, status}] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Records the final delivery outcome for a dispatched notification reference.
  """
  @spec record_outcome(reference(), :delivered | :failed) :: :ok
  def record_outcome(ref, outcome) when outcome in [:delivered, :failed] do
    :ets.insert(:notification_delivery_status, {ref, outcome})
    :ok
  end
end
```
