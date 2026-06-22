```elixir
defmodule Reporting.DigestScheduler do
  @moduledoc """
  GenServer that periodically compiles and delivers summary digest reports
  to configured recipients.

  The digest interval is configurable at startup. The server manages its
  own internal tick scheduling and delegates report compilation and mail
  delivery to purpose-built collaborator modules, keeping this module
  responsible solely for scheduling concerns.
  """
  use GenServer

  require Logger

  alias Reporting.{DigestCompiler, Mailer}

  @type state :: %{
          interval_ms: pos_integer(),
          last_sent_at: DateTime.t() | nil,
          delivery_count: non_neg_integer()
        }

  @default_interval_ms :timer.hours(24)

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Starts the digest scheduler linked to the calling supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers an immediate digest delivery outside the regular schedule."
  @spec send_now() :: :ok
  def send_now do
    GenServer.cast(__MODULE__, :send_digest)
  end

  @doc "Returns the current scheduler status snapshot."
  @spec status() :: state()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── Server callbacks ──────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule_next(interval_ms)
    {:ok, %{interval_ms: interval_ms, last_sent_at: nil, delivery_count: 0}}
  end

  @impl GenServer
  def handle_cast(:send_digest, state) do
    {:noreply, perform_digest(state)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    schedule_next(state.interval_ms)
    {:noreply, perform_digest(state)}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp perform_digest(state) do
    Logger.info("Compiling scheduled digest report")

    case DigestCompiler.compile() do
      {:ok, report} -> deliver_report(report, state)
      {:error, reason} -> log_compile_failure(reason, state)
    end
  end

  defp deliver_report(report, state) do
    case Mailer.deliver_digest(report) do
      :ok ->
        Logger.info("Digest delivered", recipients: length(report.recipients))
        %{state | last_sent_at: DateTime.utc_now(), delivery_count: state.delivery_count + 1}

      {:error, reason} ->
        Logger.error("Digest delivery failed", reason: inspect(reason))
        state
    end
  end

  defp log_compile_failure(reason, state) do
    Logger.error("Digest compilation failed", reason: inspect(reason))
    state
  end

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
```
