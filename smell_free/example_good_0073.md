```elixir
defmodule Reports.Params do
  @moduledoc """
  Typed, validated parameters for a report generation request.
  """

  @type aggregation :: :hourly | :daily | :weekly | :monthly
  @type output_format :: :json | :csv

  @type t :: %__MODULE__{
          from: Date.t(),
          to: Date.t(),
          aggregation: aggregation(),
          format: output_format(),
          page: pos_integer(),
          page_size: pos_integer()
        }

  defstruct [
    :from,
    :to,
    aggregation: :daily,
    format: :json,
    page: 1,
    page_size: 50
  ]

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_params}
  def new(%{from: %Date{} = from, to: %Date{} = to} = params) do
    if Date.compare(from, to) != :gt do
      {:ok, struct!(__MODULE__, Map.take(params, [:from, :to, :aggregation, :format, :page, :page_size]))}
    else
      {:error, :invalid_params}
    end
  end

  def new(_), do: {:error, :invalid_params}
end

defmodule Reports.Pagination do
  @moduledoc false

  @type t :: %__MODULE__{
          page: pos_integer(),
          page_size: pos_integer(),
          total_records: non_neg_integer(),
          total_pages: non_neg_integer()
        }

  defstruct [:page, :page_size, :total_records, :total_pages]

  @spec paginate([term()], pos_integer(), pos_integer()) :: {[term()], t()}
  def paginate(records, page, page_size) when page > 0 and page_size > 0 do
    total = length(records)
    total_pages = ceil(total / page_size)
    offset = (page - 1) * page_size

    slice = records |> Enum.drop(offset) |> Enum.take(page_size)

    meta = %__MODULE__{
      page: page,
      page_size: page_size,
      total_records: total,
      total_pages: max(total_pages, 1)
    }

    {slice, meta}
  end
end

defmodule Reports.Generator do
  @moduledoc """
  Assembles paginated, time-bounded reports from raw telemetry data.

  The generator coordinates data fetching, aggregation, and pagination
  as a sequential pipeline. Each step produces a typed intermediate value.
  The final result includes the formatted data slice, a summary, and
  pagination metadata allowing clients to request subsequent pages.
  """

  alias Reports.{Params, Pagination, DataFetcher, Aggregator}

  @type report :: %{
          data: [map()],
          summary: map(),
          pagination: Pagination.t()
        }

  @spec generate(Params.t()) ::
          {:ok, report()} | {:error, :data_unavailable | :aggregation_failed}
  def generate(%Params{} = params) do
    with {:ok, raw} <- DataFetcher.fetch(params.from, params.to),
         {:ok, aggregated} <- Aggregator.run(raw, params.aggregation) do
      {page_data, pagination} = Pagination.paginate(aggregated, params.page, params.page_size)
      {:ok, %{data: page_data, summary: build_summary(aggregated, params), pagination: pagination}}
    end
  end

  @spec generate_async(Params.t(), pid()) :: :ok
  def generate_async(%Params{} = params, caller) when is_pid(caller) do
    Task.Supervisor.start_child(Reports.TaskSupervisor, fn ->
      send(caller, {:report_ready, generate(params)})
    end)

    :ok
  end

  defp build_summary(aggregated, params) do
    %{
      total_records: length(aggregated),
      period_from: params.from,
      period_to: params.to,
      aggregation: params.aggregation,
      generated_at: DateTime.utc_now()
    }
  end
end
```
