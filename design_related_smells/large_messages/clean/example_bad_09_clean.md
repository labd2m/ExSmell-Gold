```elixir
defmodule Reporting.Dimension do
  defstruct [:region, :channel, :product_line, :sales_rep_id, :store_id, :campaign_id]
end

defmodule Reporting.SalesRow do
  @enforce_keys [:id, :period, :amount_cents, :dim]
  defstruct [
    :id,
    :period,
    :amount_cents,
    :units_sold,
    :cost_cents,
    :gross_margin_cents,
    :discount_cents,
    :returns_cents,
    :dim,
    :customer_segment,
    :payment_method,
    :notes
  ]
end

defmodule Reporting.SalesDataStore do
  @moduledoc "Simulates reading sales rows for a given report definition."

  @spec fetch(String.t(), Date.t(), Date.t()) :: list(Reporting.SalesRow.t())
  def fetch(report_id, _from, _to) do
    Enum.map(1..18_000, fn i ->
      amount = Enum.random(1_000..1_000_000)
      cost = div(amount * 60, 100)

      %Reporting.SalesRow{
        id: "ROW-#{report_id}-#{i}",
        period: "2024-W#{rem(i, 52) + 1}",
        amount_cents: amount,
        units_sold: rem(i, 200) + 1,
        cost_cents: cost,
        gross_margin_cents: amount - cost,
        discount_cents: div(amount, 10),
        returns_cents: if(rem(i, 50) == 0, do: div(amount, 5), else: 0),
        dim: %Reporting.Dimension{
          region: Enum.random(["north", "south", "east", "west"]),
          channel: Enum.random(["online", "retail", "wholesale"]),
          product_line: "line-#{rem(i, 15)}",
          sales_rep_id: "REP-#{rem(i, 200)}",
          store_id: "STR-#{rem(i, 50)}",
          campaign_id: "CAMP-#{rem(i, 20)}"
        },
        customer_segment: Enum.random(["smb", "mid_market", "enterprise"]),
        payment_method: Enum.random(["credit_card", "bank_transfer", "pix"]),
        notes: if(rem(i, 100) == 0, do: "Exception row #{i}", else: nil)
      }
    end)
  end
end

defmodule Reporting.CsvExporter do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{exports: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:export, report_id, rows}, state) do
    header = "id,period,amount_cents,units_sold,region,channel\n"

    body =
      rows
      |> Enum.map(fn r ->
        "#{r.id},#{r.period},#{r.amount_cents},#{r.units_sold},#{r.dim.region},#{r.dim.channel}\n"
      end)
      |> Enum.join()

    _csv = header <> body

    updated = [%{report_id: report_id, row_count: length(rows)} | state.exports]
    {:noreply, %{state | exports: updated}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.exports, state}
  end
end

defmodule Reporting.ExportScheduler do
  @moduledoc "Receives export requests, loads data, and dispatches to the CSV exporter."

  require Logger

  @spec trigger_export(pid(), String.t(), {Date.t(), Date.t()}) :: :ok
  def trigger_export(exporter_pid, report_id, {date_from, date_to}) do
    Logger.info("Triggering export for report #{report_id}")

    rows = Reporting.SalesDataStore.fetch(report_id, date_from, date_to)

    Logger.info("Fetched #{length(rows)} rows — dispatching to CSV exporter")

    GenServer.cast(exporter_pid, {:export, report_id, rows})

    :ok
  end

  @spec run_all(pid(), list(String.t())) :: :ok
  def run_all(exporter_pid, report_ids) do
    date_from = Date.utc_today() |> Date.add(-90)
    date_to = Date.utc_today()

    Enum.each(report_ids, fn rid ->
      trigger_export(exporter_pid, rid, {date_from, date_to})
    end)
  end
end
```
