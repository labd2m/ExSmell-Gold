```elixir
defmodule Pipeline.CsvProducer do
  @moduledoc """
  A GenStage producer that reads rows from a CSV file and emits them
  as structured maps keyed by header column names.
  """

  use GenStage

  alias NimbleCSV.RFC4180, as: CSV

  @type row :: %{String.t() => String.t()}
  @type state :: %{rows: [row()], demand: non_neg_integer()}

  @spec start_link(keyword()) :: GenStage.on_start()
  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl GenStage
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    rows = load_rows(path)
    {:producer, %{rows: rows, demand: 0}}
  end

  @impl GenStage
  def handle_demand(incoming, %{rows: rows, demand: pending} = state) do
    total = pending + incoming
    {emitted, remaining} = Enum.split(rows, total)
    {:noreply, emitted, %{state | rows: remaining, demand: max(total - length(emitted), 0)}}
  end

  defp load_rows(path) do
    path
    |> File.stream!()
    |> CSV.parse_stream(skip_headers: false)
    |> Stream.transform(nil, &zip_with_headers/2)
    |> Enum.to_list()
  end

  defp zip_with_headers(row, nil), do: {[], row}
  defp zip_with_headers(row, headers), do: {[Map.new(Enum.zip(headers, row))], headers}
end

defmodule Pipeline.RowValidator do
  @moduledoc """
  A GenStage consumer-producer that validates rows from `Pipeline.CsvProducer`.
  Valid rows are forwarded downstream; invalid rows are counted and discarded.
  """

  use GenStage

  require Logger

  @required_fields ~w[id name email]

  @spec start_link(keyword()) :: GenStage.on_start()
  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl GenStage
  def init(opts) do
    producer = Keyword.fetch!(opts, :producer)
    {:producer_consumer, %{discarded: 0}, subscribe_to: [producer]}
  end

  @impl GenStage
  def handle_events(events, _from, %{discarded: count} = state) do
    {valid, invalid} = Enum.split_with(events, &valid?/1)
    new_count = count + length(invalid)
    log_discarded(invalid)
    {:noreply, valid, %{state | discarded: new_count}}
  end

  defp valid?(row) when is_map(row) do
    Enum.all?(@required_fields, fn field ->
      row |> Map.get(field, "") |> String.trim() != ""
    end)
  end

  defp valid?(_), do: false

  defp log_discarded([]), do: :ok

  defp log_discarded(rows) do
    Logger.warning("[RowValidator] Discarded #{length(rows)} invalid rows")
  end
end

defmodule Pipeline.DbLoader do
  @moduledoc """
  A GenStage consumer that bulk-inserts validated rows into the database
  using Ecto's `insert_all`. Conflicts on `external_id` are ignored to
  preserve idempotency on repeated runs.
  """

  use GenStage

  alias Pipeline.Repo
  alias Pipeline.Import.Record

  @spec start_link(keyword()) :: GenStage.on_start()
  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl GenStage
  def init(opts) do
    producer = Keyword.fetch!(opts, :producer)
    batch_size = Keyword.get(opts, :batch_size, 100)
    {:consumer, %{inserted: 0}, subscribe_to: [{producer, max_demand: batch_size}]}
  end

  @impl GenStage
  def handle_events(events, _from, %{inserted: total} = state) do
    records = Enum.map(events, &to_record/1)
    {count, _} = Repo.insert_all(Record, records, on_conflict: :nothing, conflict_target: :external_id)
    {:noreply, [], %{state | inserted: total + count}}
  end

  defp to_record(%{"id" => id, "name" => name, "email" => email}) do
    %{
      external_id: id,
      name: String.trim(name),
      email: String.downcase(String.trim(email)),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
```
