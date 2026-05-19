# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Notifications.Dispatcher.flush_pending/1` |
| **Affected function(s)** | `flush_pending/1` |
| **Short explanation** | The dispatcher fetches the entire pending notification queue (potentially tens of thousands of fully hydrated notification records with rendered templates and metadata) and sends the whole list in one message to the delivery worker. This single message can be very large and causes the sender to block while the BEAM copies the structure to the worker's heap. |

```elixir
defmodule Notifications.Template do
  @enforce_keys [:id, :channel, :subject, :body_html, :body_text]
  defstruct [:id, :channel, :subject, :body_html, :body_text, :variables]

  @type t :: %__MODULE__{
          id: String.t(),
          channel: :email | :sms | :push,
          subject: String.t() | nil,
          body_html: String.t() | nil,
          body_text: String.t(),
          variables: map()
        }
end

defmodule Notifications.Recipient do
  @enforce_keys [:id, :email, :phone, :push_tokens, :locale]
  defstruct [:id, :email, :phone, :push_tokens, :locale, :preferences, :timezone]

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          phone: String.t() | nil,
          push_tokens: [String.t()],
          locale: String.t(),
          preferences: map(),
          timezone: String.t()
        }
end

defmodule Notifications.PendingNotification do
  @enforce_keys [:id, :recipient, :template, :scheduled_at, :priority]
  defstruct [:id, :recipient, :template, :scheduled_at, :priority, :retries, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          recipient: Notifications.Recipient.t(),
          template: Notifications.Template.t(),
          scheduled_at: DateTime.t(),
          priority: :low | :normal | :high | :critical,
          retries: non_neg_integer(),
          metadata: map()
        }
end

defmodule Notifications.Queue do
  @moduledoc "In-memory queue of pending notifications."

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def drain, do: GenServer.call(__MODULE__, :drain, 30_000)

  @impl true
  def init(_), do: {:ok, build_queue()}

  @impl true
  def handle_call(:drain, _from, queue) do
    {:reply, queue, []}
  end

  defp build_queue do
    now = DateTime.utc_now()

    Enum.map(1..20_000, fn n ->
      %Notifications.PendingNotification{
        id: "notif_#{n}",
        recipient: %Notifications.Recipient{
          id: "usr_#{n}",
          email: "user#{n}@example.com",
          phone: "+1555#{String.pad_leading("#{n}", 7, "0")}",
          push_tokens: Enum.map(1..3, fn t -> "tok_#{n}_#{t}_#{:rand.uniform(999_999)}" end),
          locale: Enum.random(["en-US", "pt-BR", "es-ES", "fr-FR"]),
          preferences: %{
            marketing: true,
            transactional: true,
            frequency: "immediate",
            channel_priority: ["push", "email", "sms"]
          },
          timezone: "America/Sao_Paulo"
        },
        template: %Notifications.Template{
          id: "tmpl_#{rem(n, 50)}",
          channel: Enum.random([:email, :push, :sms]),
          subject: "Your account update – reference #{n}",
          body_html:
            "<html><body><h1>Hello user #{n}</h1><p>" <>
              String.duplicate("This is important account information. ", 30) <>
              "</p></body></html>",
          body_text:
            "Hello user #{n}. " <>
              String.duplicate("This is important account information. ", 30),
          variables: %{
            user_id: "usr_#{n}",
            action_url: "https://app.example.com/action/#{n}",
            expires_at: DateTime.add(now, 86_400, :second)
          }
        },
        scheduled_at: DateTime.add(now, rem(n, 3600), :second),
        priority: Enum.random([:low, :normal, :high]),
        retries: 0,
        metadata: %{
          campaign_id: "camp_#{rem(n, 20)}",
          source: "billing_event",
          trace_id: "trace_#{n}_#{:rand.uniform(999_999)}"
        }
      }
    end)
  end
end

defmodule Notifications.DeliveryWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:deliver_batch, notifications}, _state) do
    # In production, each notification would be dispatched via the appropriate
    # channel adapter (SMTP, Twilio, FCM, etc.).
    {:noreply, notifications}
  end
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Drains the pending notification queue and forwards the batch
  to the delivery worker for channel-specific dispatch.
  """

  require Logger

  @spec flush_pending(pid()) :: :ok
  def flush_pending(worker_pid) do
    Logger.info("Draining notification queue...")

    notifications = Notifications.Queue.drain()
    count = length(notifications)

    Logger.info("Drained #{count} notifications. Forwarding to delivery worker...")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `notifications` is a list of up to
    # 20,000 fully hydrated structs, each embedding a Recipient (with 3 push
    # tokens, preferences map) and a Template (with a long HTML body string).
    # Sending this entire list as one message causes a massive heap-to-heap
    # copy inside the BEAM, blocking the sender process and potentially
    # causing significant latency spikes across the system.
    send(worker_pid, {:deliver_batch, notifications})
    # VALIDATION: SMELL END

    Logger.info("Batch of #{count} notifications dispatched.")
    :ok
  end
end
```
