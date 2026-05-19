# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `ReportAggregator.start/1`
- **Affected function(s):** `ReportAggregator.start/1`, `ReportingService.build_report/2`
- **Short explanation:** One `GenServer` per report is instantiated using `GenServer.start/3` to accumulate data from multiple sources before rendering. Since it lives outside a supervision tree, a crash mid-aggregation causes silent data loss with no automatic restart.

```elixir
defmodule ReportAggregator do
  use GenServer

  @moduledoc """
  Collects and aggregates metrics from multiple data sources
  to produce a consolidated business report.
  """

  defstruct [
    :report_id,
    :report_type,
    :period_start,
    :period_end,
    :requested_by,
    sections: %{},
    status: :collecting
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because report aggregators are long-lived processes
  # that coordinate data collection across multiple services. Started via
  # `GenServer.start/3` outside any supervisor, a crash while collecting data
  # from one section silently destroys the entire aggregation context. The caller
  # has no way to know the process is gone, and no automatic recovery is possible.
  def start(%{report_id: id} = spec) do
    GenServer.start(__MODULE__, spec, name: via(id))
  end
  # VALIDATION: SMELL END

  def add_section(report_id, section_name, data) do
    GenServer.call(via(report_id), {:add_section, section_name, data})
  end

  def finalize(report_id) do
    GenServer.call(via(report_id), :finalize, 30_000)
  end

  def status(report_id) do
    GenServer.call(via(report_id), :status)
  end

  defp via(id), do: {:via, Registry, {ReportRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{report_id: id, report_type: type, period_start: ps, period_end: pe, requested_by: rb}) do
    state = %__MODULE__{
      report_id: id,
      report_type: type,
      period_start: ps,
      period_end: pe,
      requested_by: rb
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_section, name, data}, _from, %{status: :collecting} = state) do
    sections = Map.put(state.sections, name, data)
    {:reply, :ok, %{state | sections: sections}}
  end

  def handle_call({:add_section, _name, _data}, _from, state) do
    {:reply, {:error, :report_finalized}, state}
  end

  def handle_call(:finalize, _from, %{status: :collecting} = state) do
    rendered = render_report(state)
    {:reply, {:ok, rendered}, %{state | status: :finalized}}
  end

  def handle_call(:finalize, _from, state) do
    {:reply, {:error, :already_finalized}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, sections: Map.keys(state.sections)}, state}
  end

  defp render_report(state) do
    %{
      report_id: state.report_id,
      type: state.report_type,
      period: %{from: state.period_start, to: state.period_end},
      generated_at: DateTime.utc_now(),
      requested_by: state.requested_by,
      sections: state.sections,
      summary: compute_summary(state.sections)
    }
  end

  defp compute_summary(sections) do
    total_revenue =
      sections
      |> Map.values()
      |> Enum.flat_map(&List.wrap(Map.get(&1, :revenue_lines, [])))
      |> Enum.reduce(Decimal.new("0"), fn %{amount: a}, acc -> Decimal.add(acc, a) end)

    %{total_revenue: total_revenue, section_count: map_size(sections)}
  end
end

defmodule ReportingService do
  @moduledoc "Orchestrates multi-section report generation."

  @sections [:sales, :refunds, :subscriptions, :churn]

  def build_report(report_id, opts) do
    spec = %{
      report_id: report_id,
      report_type: Keyword.get(opts, :type, :monthly),
      period_start: Keyword.fetch!(opts, :from),
      period_end: Keyword.fetch!(opts, :to),
      requested_by: Keyword.fetch!(opts, :requested_by)
    }

    {:ok, _pid} = ReportAggregator.start(spec)

    Enum.each(@sections, fn section ->
      data = fetch_section_data(section, spec.period_start, spec.period_end)
      ReportAggregator.add_section(report_id, section, data)
    end)

    ReportAggregator.finalize(report_id)
  end

  defp fetch_section_data(:sales, _from, _to), do: %{revenue_lines: [%{amount: Decimal.new("5000")}]}
  defp fetch_section_data(:refunds, _from, _to), do: %{revenue_lines: [%{amount: Decimal.new("-200")}]}
  defp fetch_section_data(:subscriptions, _from, _to), do: %{active: 340, new: 15, cancelled: 8}
  defp fetch_section_data(:churn, _from, _to), do: %{rate: 0.023, count: 8}
end
```
