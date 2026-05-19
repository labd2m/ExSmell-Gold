```elixir
defmodule MailerWorker do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{sent: 0, failed: 0}, opts)
  end

  def stats(pid), do: GenServer.call(pid, :stats)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:send_digest, channel, payloads}, _from, state) do
    Logger.info("MailerWorker: dispatching #{length(payloads)} messages on channel=#{channel}")

    {sent, failed} =
      Enum.reduce(payloads, {0, 0}, fn payload, {s, f} ->
        case simulate_send(channel, payload) do
          :ok -> {s + 1, f}
          {:error, _reason} -> {s, f + 1}
        end
      end)

    Logger.info("MailerWorker: sent=#{sent} failed=#{failed}")

    new_state = %{state | sent: state.sent + sent, failed: state.failed + failed}
    {:reply, {:ok, %{sent: sent, failed: failed}}, new_state}
  end

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ignored, state}

  defp simulate_send(_channel, _payload), do: :ok
end

defmodule NotificationDispatcher do
  require Logger

  @doc """
  Builds personalised digest payloads for every active subscriber and sends
  them to the mailer worker for delivery. Supports `:email` and `:push`
  channels.
  """
  def dispatch_digest(mailer_pid, channel) do
    Logger.info("NotificationDispatcher: building digest payloads for channel=#{channel}")

    payloads = build_all_payloads(channel)

    Logger.info("NotificationDispatcher: #{length(payloads)} payloads ready — calling mailer")

    GenServer.call(mailer_pid, {:send_digest, channel, payloads}, :infinity)

  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate building large personalised payloads
  # ---------------------------------------------------------------------------

  defp build_all_payloads(channel) do
    Enum.map(1..25_000, fn n ->
      subscriber_id = "SUB-#{String.pad_leading(Integer.to_string(n), 8, "0")}"

      %{
        subscriber_id: subscriber_id,
        channel: channel,
        address: "user#{n}@example.com",
        subject: "Your weekly digest — #{Date.utc_today()}",
        body: build_body(n),
        preferences: %{
          locale: Enum.random(["en", "pt", "es", "fr", "de"]),
          timezone: Enum.random(["UTC", "America/New_York", "Europe/Berlin"]),
          format: Enum.random([:html, :plain])
        },
        tracking: %{
          campaign_id: "CAMP-2024-06",
          utm_source: "weekly_digest",
          utm_medium: channel,
          batch_id: "BATCH-#{Date.utc_today()}"
        },
        scheduled_at: DateTime.utc_now()
      }
    end)
  end

  defp build_body(n) do
    articles =
      Enum.map(1..10, fn i ->
        "Article #{i} for subscriber #{n}: " <> String.duplicate("content ", 50)
      end)

    Enum.join(articles, "\n\n")
  end
end
```
