```elixir
defmodule Audit.EventLogger do
  @moduledoc """
  Persists immutable audit-trail events to a centralised audit service.
  Events capture who did what to which resource and when, and are used
  for compliance, security forensics, and operational dashboards.

  Events are buffered in a GenServer and delivered asynchronously in
  micro-batches to reduce pressure on the audit service.
  """

  use GenServer
  require Logger

  @flush_interval_ms 3_000
  @max_buffer_events 100
  @delivery_timeout_ms 10_000

  @audit_service_url Application.fetch_env!(:audit, :service_url)

  @type actor :: %{id: String.t(), type: :user | :service | :system}
  @type resource :: %{id: String.t(), type: String.t()}
  @type event_action ::
          :created | :updated | :deleted | :viewed | :exported
          | :login_success | :login_failure | :permission_denied

  @type audit_event :: %{
          actor: actor(),
          action: event_action(),
          resource: resource(),
          metadata: map(),
          occurred_at: DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a single audit event for asynchronous delivery.

  ## Parameters
    - `actor` - The entity performing the action (user, service, or system).
    - `action` - The action atom (`:created`, `:deleted`, etc.).
    - `resource` - The resource being acted upon.
    - `metadata` - Optional extra context, e.g. `%{ip: "1.2.3.4", reason: "admin override"}`.
  """
  @spec log_event(actor(), event_action(), resource(), map()) :: :ok
  def log_event(actor, action, resource, metadata \\ %{}) do
    event = %{
      actor: actor,
      action: action,
      resource: resource,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:enqueue, event})
  end

  @doc """
  Enqueues multiple events in a single call.
  """
  @spec log_bulk([audit_event()]) :: :ok
  def log_bulk(events) when is_list(events) do
    GenServer.cast(__MODULE__, {:enqueue_bulk, events})
  end

  @doc """
  Forces an immediate flush of the internal buffer.
  Returns `{:ok, count}` with the number of events delivered.
  """
  @spec flush() :: {:ok, non_neg_integer()} | {:error, term()}
  def flush do
    GenServer.call(__MODULE__, :flush, @delivery_timeout_ms + 1_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    schedule_flush()
    {:ok, %{buffer: [], failed: 0, delivered: 0}}
  end

  @impl GenServer
  def handle_cast({:enqueue, event}, %{buffer: buf} = state) do
    new_buf = [event | buf]

    if length(new_buf) >= @max_buffer_events do
      {:ok, n} = deliver_events(new_buf)
      {:noreply, %{state | buffer: [], delivered: state.delivered + n}}
    else
      {:noreply, %{state | buffer: new_buf}}
    end
  end

  def handle_cast({:enqueue_bulk, events}, %{buffer: buf} = state) do
    combined = events ++ buf

    if length(combined) >= @max_buffer_events do
      {:ok, n} = deliver_events(combined)
      {:noreply, %{state | buffer: [], delivered: state.delivered + n}}
    else
      {:noreply, %{state | buffer: combined}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{buffer: buf} = state) do
    result = deliver_events(buf)
    n = if match?({:ok, _}, result), do: elem(result, 1), else: 0
    {:reply, result, %{state | buffer: [], delivered: state.delivered + n}}
  end

  @impl GenServer
  def handle_info(:flush, %{buffer: []} = state) do
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(:flush, %{buffer: buf} = state) do
    {:ok, n} = deliver_events(buf)
    schedule_flush()
    {:noreply, %{state | buffer: [], delivered: state.delivered + n}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp deliver_events([]), do: {:ok, 0}

  defp deliver_events(events) do
    payload = Jason.encode!(%{events: Enum.reverse(events)})
    headers = [{"Content-Type", "application/json"}, {"X-Service", "audit-logger"}]
    url = @audit_service_url <> "/events/batch"

    case HTTPoison.post(url, payload, headers, recv_timeout: @delivery_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: code}} when code in 200..204 ->
        Logger.info("Audit events delivered count=#{length(events)}")
        {:ok, length(events)}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        Logger.error("Audit delivery rejected status=#{code} body=#{body}")
        {:error, {:rejected, code}}

      {:error, reason} ->
        Logger.error("Audit delivery failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
```
