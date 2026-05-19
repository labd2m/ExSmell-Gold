# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Reporting.ExportCoordinator.send_to_renderer/2` |
| **Affected function(s)** | `send_to_renderer/2` |
| **Short explanation** | The coordinator assembles a complete report dataset in the calling process and forwards the entire structure—including thousands of rows with nested breakdown maps—to a separate renderer process via a single message. This forces the BEAM to deep-copy what can be tens of megabytes across process heaps. |

```elixir
defmodule Reporting.DimensionBreakdown do
  defstruct [:dimension, :value, :row_count, :subtotals]

  @type t :: %__MODULE__{
          dimension: String.t(),
          value: String.t(),
          row_count: non_neg_integer(),
          subtotals: %{String.t() => float()}
        }
end

defmodule Reporting.DataRow do
  @enforce_keys [:id, :period, :metrics, :dimensions]
  defstruct [:id, :period, :metrics, :dimensions, :breakdowns, :annotations]

  @type t :: %__MODULE__{
          id: String.t(),
          period: {Date.t(), Date.t()},
          metrics: %{String.t() => float()},
          dimensions: %{String.t() => String.t()},
          breakdowns: [Reporting.DimensionBreakdown.t()],
          annotations: [String.t()]
        }
end

defmodule Reporting.ReportSpec do
  @enforce_keys [:id, :name, :requested_by, :date_range, :filters]
  defstruct [:id, :name, :requested_by, :date_range, :filters, :format, :include_breakdowns]
end

defmodule Reporting.DataWarehouse do
  @moduledoc "Simulates a call to an analytical data warehouse."

  @spec query(Reporting.ReportSpec.t()) :: [Reporting.DataRow.t()]
  def query(%Reporting.ReportSpec{date_range: {from, to}}) do
    days = Date.diff(to, from)

    Enum.flat_map(0..days, fn d ->
      date = Date.add(from, d)

      Enum.map(1..200, fn row_n ->
        %Reporting.DataRow{
          id: "row_#{Date.to_iso8601(date)}_#{row_n}",
          period: {date, date},
          metrics: %{
            "revenue" => :rand.uniform() * 10_000,
            "units_sold" => :rand.uniform(500),
            "refunds" => :rand.uniform() * 500,
            "gross_margin" => :rand.uniform() * 0.8,
            "avg_order_value" => :rand.uniform() * 200,
            "conversion_rate" => :rand.uniform() * 0.15,
            "cac" => :rand.uniform() * 80
          },
          dimensions: %{
            "region" => Enum.random(["NA", "EMEA", "APAC", "LATAM"]),
            "channel" => Enum.random(["web", "mobile", "partner", "direct"]),
            "product_line" => "PL-#{rem(row_n, 10) + 1}",
            "account_tier" => Enum.random(["free", "starter", "pro", "enterprise"])
          },
          breakdowns:
            Enum.map(1..8, fn b ->
              %Reporting.DimensionBreakdown{
                dimension: "segment_#{b}",
                value: "val_#{rem(row_n * b, 20)}",
                row_count: :rand.uniform(1000),
                subtotals: %{
                  "revenue" => :rand.uniform() * 1000,
                  "units" => :rand.uniform(100) * 1.0
                }
              }
            end),
          annotations:
            if(rem(row_n, 50) == 0,
              do: ["outlier detected", "manual review required"],
              else: []
            )
        }
      end)
    end)
  end
end

defmodule Reporting.RendererWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_info({:render, spec, rows}, _state) do
    # Render rows into CSV/XLSX/PDF according to spec.format
    _ = {spec, rows}
    {:noreply, :rendered}
  end
end

defmodule Reporting.ExportCoordinator do
  @moduledoc """
  Orchestrates the export of a report: fetches data from the warehouse
  and sends it to a renderer worker process for formatting.
  """

  require Logger

  @spec send_to_renderer(pid(), Reporting.ReportSpec.t()) :: :ok
  def send_to_renderer(renderer_pid, %Reporting.ReportSpec{} = spec) do
    Logger.info("Querying data warehouse for report '#{spec.name}' (id=#{spec.id})...")

    rows = Reporting.DataWarehouse.query(spec)

    Logger.info("Warehouse returned #{length(rows)} rows. Sending to renderer...")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `rows` is a list that can contain
    # tens of thousands of DataRow structs, each with 7 metric entries, 4
    # dimension entries, and 8 DimensionBreakdown sub-structs. Sending this
    # entire list plus the spec as a single process message forces a full
    # deep-copy of all this data across heap boundaries, blocking the
    # coordinator process and potentially causing it to miss other work.
    send(renderer_pid, {:render, spec, rows})
    # VALIDATION: SMELL END

    Logger.info("Render job dispatched for report '#{spec.name}'.")
    :ok
  end
end
```
