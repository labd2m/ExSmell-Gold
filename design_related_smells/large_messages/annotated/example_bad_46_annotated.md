# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `ReportCompiler.compile/2` — the `GenServer.call/3` that sends the full raw dataset to the renderer process
- **Affected function(s):** `ReportCompiler.compile/2`, `ReportRenderer.handle_call/3`
- **Short explanation:** An entire analytics dataset — a large list of event maps covering millions of user actions — is passed as the argument of a synchronous `GenServer.call` to the renderer. All of that data must be copied into the renderer's heap before the call can begin, blocking the compiler process for the full copy duration on every report run.

---

```elixir
defmodule ReportRenderer do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{renders: 0}, opts)
  end

  def renders(pid), do: GenServer.call(pid, :renders)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:renders, _from, state), do: {:reply, state.renders, state}

  @impl true
  def handle_call({:render_report, report_type, rows}, _from, state) do
    Logger.info("ReportRenderer: rendering #{report_type} report — #{length(rows)} rows")

    output = do_render(report_type, rows)

    {:reply, {:ok, output}, %{state | renders: state.renders + 1}}
  end

  defp do_render(report_type, rows) do
    total_events = length(rows)
    unique_users = rows |> Enum.map(& &1.user_id) |> Enum.uniq() |> length()

    %{
      report_type: report_type,
      generated_at: DateTime.utc_now(),
      summary: %{total_events: total_events, unique_users: unique_users},
      sample: Enum.take(rows, 10)
    }
  end
end

defmodule ReportCompiler do
  require Logger

  @doc """
  Fetches raw event data for the given report type and time window, then
  sends the dataset to the renderer process to produce the final report
  structure. Used by the scheduled reporting pipeline.
  """
  def compile(renderer_pid, report_type) do
    Logger.info("ReportCompiler: loading raw data for report=#{report_type}")

    rows = load_raw_data(report_type)

    Logger.info("ReportCompiler: #{length(rows)} rows loaded — calling renderer")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the entire raw analytics dataset —
    # up to 500 000 event maps per report, each carrying user IDs, event
    # properties, session context, and timestamps — is deep-copied into the
    # ReportRenderer process heap as the argument of a synchronous
    # GenServer.call. The compiler process is blocked until copying completes,
    # and the renderer must hold two full copies of the dataset (the message
    # and any internal reference) simultaneously in memory.
    result = GenServer.call(renderer_pid, {:render_report, report_type, rows}, :infinity)
    # VALIDATION: SMELL END

    result
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate loading a large analytics dataset
  # ---------------------------------------------------------------------------

  defp load_raw_data(report_type) do
    Enum.map(1..500_000, fn n ->
      %{
        event_id: "EVT-#{n}",
        report_type: report_type,
        user_id: "USR-#{:rand.uniform(100_000)}",
        session_id: "SESS-#{:rand.uniform(500_000)}",
        event_name: Enum.random(["page_view", "click", "purchase", "signup", "search"]),
        properties: %{
          page: "/page/#{:rand.uniform(500)}",
          referrer: Enum.random(["google", "direct", "email", "social"]),
          duration_ms: :rand.uniform(30_000),
          ab_variant: Enum.random(["control", "variant_a", "variant_b"])
        },
        device: %{
          type: Enum.random([:desktop, :mobile, :tablet]),
          os: Enum.random(["macOS", "Windows", "iOS", "Android"]),
          browser: Enum.random(["Chrome", "Safari", "Firefox"])
        },
        occurred_at: DateTime.add(~U[2024-05-01 00:00:00Z], n, :second)
      }
    end)
  end
end
```
