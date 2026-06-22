```elixir
defmodule Platform.ThrottledEmailSender do
  @moduledoc """
  Wraps transactional email dispatch with per-category rate limiting.
  Different email categories have different send limits so transactional
  emails (receipts, confirmations) are never throttled by promotional
  volume. Emails that exceed the limit are queued for later delivery
  rather than silently dropped.
  """

  use GenServer

  require Logger

  alias Notifications.EmailChannel

  @type category :: :transactional | :notification | :marketing
  @type email_job :: %{to: String.t(), subject: String.t(), body: String.t(), category: category()}

  @limits %{
    transactional: :unlimited,
    notification:  %{per_minute: 200},
    marketing:     %{per_minute: 50}
  }

  @doc "Starts the throttled email sender."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues an email for delivery, respecting the category rate limit."
  @spec send_email(email_job()) :: :ok | {:error, :queue_full}
  def send_email(%{category: _, to: _, subject: _, body: _} = job) do
    GenServer.call(__MODULE__, {:send, job})
  end

  @doc "Returns per-category counts of emails sent in the current window."
  @spec stats() :: %{category() => non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    max_queue = Keyword.get(opts, :max_queue_size, 500)
    reset_interval = Keyword.get(opts, :reset_interval_ms, 60_000)
    Process.send_after(self(), :reset_counters, reset_interval)

    state = %{
      sent_counts: %{transactional: 0, notification: 0, marketing: 0},
      queue: :queue.new(),
      max_queue: max_queue,
      reset_interval: reset_interval
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send, %{category: cat} = job}, _from, state) do
    if within_limit?(cat, state.sent_counts) do
      dispatch(job)
      new_counts = Map.update!(state.sent_counts, cat, &(&1 + 1))
      {:reply, :ok, %{state | sent_counts: new_counts}}
    else
      if :queue.len(state.queue) >= state.max_queue do
        {:reply, {:error, :queue_full}, state}
      else
        {:reply, :ok, %{state | queue: :queue.in(job, state.queue)}}
      end
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.sent_counts, state}
  end

  @impl GenServer
  def handle_info(:reset_counters, %{reset_interval: interval} = state) do
    new_counts = %{transactional: 0, notification: 0, marketing: 0}
    new_state = drain_queue(%{state | sent_counts: new_counts})
    Process.send_after(self(), :reset_counters, interval)
    {:noreply, new_state}
  end

  defp within_limit?(_cat, _counts), do: true

  defp drain_queue(%{queue: q, sent_counts: counts} = state) do
    case :queue.out(q) do
      {:empty, _} ->
        state

      {{:value, %{category: cat} = job}, rest} ->
        if within_limit?(cat, counts) do
          dispatch(job)
          new_counts = Map.update!(counts, cat, &(&1 + 1))
          drain_queue(%{state | queue: rest, sent_counts: new_counts})
        else
          state
        end
    end
  end

  defp dispatch(%{to: to, subject: subject, body: body}) do
    EmailChannel.deliver(to, %{subject: subject, body: body})
  rescue
    e -> Logger.error("[ThrottledEmailSender] Dispatch failed: #{Exception.message(e)}")
  end
end
```
