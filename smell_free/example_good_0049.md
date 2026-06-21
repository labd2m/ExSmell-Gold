```elixir
defmodule Notifications.Channel do
  @moduledoc """
  Behaviour contract that all notification channel implementations must satisfy.
  Each implementation is responsible for a single delivery modality such as
  transactional email, SMS, or push notification.
  """

  @type recipient_id :: String.t()
  @type payload :: map()
  @type result :: :ok | {:error, :invalid_recipient | :delivery_failed | :rate_limited}

  @doc "Delivers a notification payload to the given recipient."
  @callback deliver(recipient_id(), payload()) :: result()
end

defmodule Notifications.EmailChannel do
  @moduledoc "Delivers notifications to users via transactional email."

  @behaviour Notifications.Channel

  require Logger

  @impl Notifications.Channel
  @spec deliver(String.t(), map()) :: Notifications.Channel.result()
  def deliver(recipient_id, payload) when is_binary(recipient_id) and is_map(payload) do
    with {:ok, address} <- resolve_address(recipient_id),
         :ok <- transmit(address, payload) do
      :ok
    end
  end

  defp resolve_address(recipient_id) do
    case MyApp.Accounts.fetch_user_email(recipient_id) do
      {:ok, email} when is_binary(email) -> {:ok, email}
      {:error, :not_found} -> {:error, :invalid_recipient}
    end
  end

  defp transmit(address, %{subject: subject, body: body}) do
    Logger.info("[EmailChannel] → #{address}: #{subject}")
    MyApp.Mailer.deliver(to: address, subject: subject, body: body)
    :ok
  rescue
    _ -> {:error, :delivery_failed}
  end

  defp transmit(_address, _payload), do: {:error, :delivery_failed}
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes notification events to the delivery channels configured for their
  event type. Each channel is invoked in a supervised task so the dispatcher
  itself remains non-blocking. Delivery results are collected and returned
  in routing-table order.
  """

  @routing_table %{
    order_placed: [Notifications.EmailChannel],
    order_shipped: [Notifications.EmailChannel],
    password_reset: [Notifications.EmailChannel],
    payment_failed: [Notifications.EmailChannel]
  }

  @task_timeout_ms 5_000

  @type event_type :: :order_placed | :order_shipped | :password_reset | :payment_failed
  @type event :: %{type: event_type(), recipient_id: String.t(), payload: map()}
  @type results :: [{:ok, term()} | {:exit, term()}]

  @doc """
  Dispatches the event to all channels mapped for its type. Returns a list
  of per-channel results in the order defined by the routing table.
  """
  @spec dispatch(event()) :: results()
  def dispatch(%{type: type, recipient_id: id, payload: payload})
      when is_atom(type) and is_binary(id) and is_map(payload) do
    @routing_table
    |> Map.get(type, [])
    |> Enum.map(fn channel ->
      Task.Supervisor.async_nolink(
        Notifications.TaskSupervisor,
        fn -> channel.deliver(id, payload) end
      )
    end)
    |> Enum.map(&collect_result/1)
  end

  defp collect_result(task) do
    case Task.yield(task, @task_timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:exit, reason}
      nil -> {:exit, :timeout}
    end
  end
end
```
