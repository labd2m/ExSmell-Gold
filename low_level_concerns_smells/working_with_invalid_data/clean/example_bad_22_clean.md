```elixir
defmodule MyApp.Reporting.ReportExporter do
  @moduledoc """
  Generates and exports filtered data reports in multiple formats (CSV, JSON, XLSX).
  Supports column selection, sorting, row limits, and asynchronous delivery via email.
  """

  require Logger

  alias MyApp.Reporting.{DataQuery, ColumnFormatter, FileBuilder, DeliveryMailer}
  alias MyApp.Accounts.User

  @default_limit 1_000
  @max_limit 50_000
  @supported_formats [:csv, :json, :xlsx]
  @temp_dir "/tmp/report_exports"

  @type export_opts :: [
          limit: pos_integer(),
          columns: [String.t()] | :all,
          sort_by: String.t() | nil,
          sort_dir: :asc | :desc,
          filters: map(),
          deliver_to_email: String.t() | nil
        ]

  @spec export(User.t(), String.t(), export_opts()) ::
          {:ok, String.t()} | {:error, atom()}
  def export(requester, format, opts \\ []) do
    columns = Keyword.get(opts, :columns, :all)
    sort_by = Keyword.get(opts, :sort_by)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)
    filters = Keyword.get(opts, :filters, %{})
    deliver_to = Keyword.get(opts, :deliver_to_email)

    limit = Keyword.get(opts, :limit, @default_limit)

    with :ok <- validate_format(format),
         :ok <- validate_sort_dir(sort_dir),
         {:ok, raw_records} <- DataQuery.run(filters, sort_by, sort_dir) do

      records = Enum.take(raw_records, limit)

      formatted_columns = resolve_columns(raw_records, columns)
      rows = ColumnFormatter.format_rows(records, formatted_columns)

      file_path = build_temp_path(format)

      with {:ok, file_path} <- FileBuilder.write(file_path, rows, formatted_columns, format),
           :ok <- maybe_deliver(file_path, deliver_to, requester, format) do
        Logger.info(
          "Report exported: format=#{format} rows=#{length(rows)} user=#{requester.id} " <>
            "limit=#{limit} delivered=#{deliver_to != nil}"
        )

        {:ok, file_path}
      end
    end
  end

  @spec schedule_export(User.t(), String.t(), export_opts()) ::
          {:ok, String.t()} | {:error, atom()}
  def schedule_export(requester, format, opts) do
    job_id = Ecto.UUID.generate()

    Task.start(fn ->
      case export(requester, format, opts) do
        {:ok, path} ->
          Logger.info("Scheduled export completed: job=#{job_id} path=#{path}")

        {:error, reason} ->
          Logger.error("Scheduled export failed: job=#{job_id} reason=#{inspect(reason)}")
      end
    end)

    {:ok, job_id}
  end

  @spec available_columns(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def available_columns(report_type) do
    DataQuery.describe_columns(report_type)
  end

  # Private helpers

  defp validate_format(format) when format in @supported_formats, do: :ok
  defp validate_format(_), do: {:error, :unsupported_format}

  defp validate_sort_dir(dir) when dir in [:asc, :desc], do: :ok
  defp validate_sort_dir(_), do: {:error, :invalid_sort_direction}

  defp resolve_columns([], _columns), do: []
  defp resolve_columns([first | _], :all), do: Map.keys(first)
  defp resolve_columns(_records, columns) when is_list(columns), do: columns

  defp build_temp_path(format) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "#{@temp_dir}/export_#{timestamp}_#{:rand.uniform(9999)}.#{format}"
  end

  defp maybe_deliver(_path, nil, _requester, _format), do: :ok

  defp maybe_deliver(path, email, requester, format) do
    DeliveryMailer.send_report(%{
      to: email,
      file_path: path,
      format: format,
      requester_name: requester.name
    })
  end
end
```
