```elixir
defmodule Imports.BulkContactImporter do
  @moduledoc """
  Processes bulk contact imports from uploaded CSV files. Runs as an Oban
  worker so imports survive server restarts. Progress is broadcast via
  Phoenix PubSub at regular row intervals so the initiating LiveView can
  render a live progress bar without polling. Each row is validated and
  upserted individually to maximise partial success; all row-level errors
  are collected and written to an error report attached to the import record.
  """

  use Oban.Worker, queue: :imports, max_attempts: 2

  alias Imports.{ContactRow, ErrorReport, ImportRecord, Repo}
  alias NimbleCSV.RFC4180, as: CSV

  require Logger

  @progress_broadcast_every 100
  @pubsub_topic_prefix "import:progress:"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => import_id}}) do
    with {:ok, record} <- fetch_import(import_id),
         :ok <- mark_running(record),
         {:ok, csv_binary} <- load_csv(record),
         result <- process_rows(csv_binary, record),
         :ok <- finalise(record, result) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private pipeline
  # ---------------------------------------------------------------------------

  defp fetch_import(import_id) do
    case Repo.get(ImportRecord, import_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp mark_running(record) do
    record
    |> ImportRecord.status_changeset(:running)
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_csv(%ImportRecord{file_key: key}) do
    case MyApp.Storage.get_object(key) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp process_rows(csv_binary, record) do
    rows =
      csv_binary
      |> CSV.parse_string(skip_headers: true)
      |> Enum.with_index(2)

    total = length(rows)
    broadcast_progress(record.id, 0, total, 0, 0)

    Enum.reduce(rows, {0, 0, []}, fn {row, line_num}, {ok, fail, errors} ->
      case process_single_row(row, line_num, record) do
        :ok ->
          new_ok = ok + 1
          maybe_broadcast(record.id, new_ok + fail, total, new_ok, fail)
          {new_ok, fail, errors}

        {:error, reason} ->
          new_fail = fail + 1
          error_entry = %{line: line_num, reason: format_reason(reason), raw: Enum.join(row, ",")}
          {ok, new_fail, [error_entry | errors]}
      end
    end)
  end

  defp process_single_row(row, line_num, record) do
    with {:ok, attrs} <- parse_row(row, line_num),
         {:ok, _contact} <- upsert_contact(attrs, record.owner_id) do
      :ok
    end
  end

  defp parse_row([email, first_name, last_name | rest], _line) do
    phone = Enum.at(rest, 0)

    if valid_email?(email) do
      {:ok, %{email: String.trim(email), first_name: String.trim(first_name),
               last_name: String.trim(last_name), phone: phone}}
    else
      {:error, {:invalid_email, email}}
    end
  end

  defp parse_row(_row, line), do: {:error, {:insufficient_columns, line}}

  defp upsert_contact(attrs, owner_id) do
    full_attrs = Map.put(attrs, :owner_id, owner_id)

    %ContactRow{}
    |> ContactRow.changeset(full_attrs)
    |> Repo.insert(on_conflict: {:replace, [:first_name, :last_name, :phone, :updated_at]},
                   conflict_target: [:email, :owner_id])
  end

  defp finalise(record, {ok_count, fail_count, errors}) do
    error_report_key = write_error_report(record.id, errors)

    record
    |> ImportRecord.complete_changeset(%{
      status: if(fail_count == 0, do: :completed, else: :completed_with_errors),
      rows_succeeded: ok_count,
      rows_failed: fail_count,
      error_report_key: error_report_key
    })
    |> Repo.update()

    broadcast_progress(record.id, ok_count + fail_count, ok_count + fail_count, ok_count, fail_count)
    Logger.info("Import complete", import_id: record.id, succeeded: ok_count, failed: fail_count)
    :ok
  end

  defp write_error_report(_import_id, []), do: nil

  defp write_error_report(import_id, errors) do
    key = "error_reports/#{import_id}.json"
    MyApp.Storage.put_object(key, Jason.encode!(errors), content_type: "application/json")
    key
  end

  defp maybe_broadcast(import_id, processed, total, ok, fail) do
    if rem(processed, @progress_broadcast_every) == 0 do
      broadcast_progress(import_id, processed, total, ok, fail)
    end
  end

  defp broadcast_progress(import_id, processed, total, succeeded, failed) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic_prefix <> import_id, {
      :import_progress,
      %{processed: processed, total: total, succeeded: succeeded, failed: failed}
    })
  end

  defp valid_email?(email), do: Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, email)
  defp format_reason({:invalid_email, e}), do: "Invalid email: #{e}"
  defp format_reason({:insufficient_columns, l}), do: "Row #{l} has too few columns"
  defp format_reason(other), do: inspect(other)
end
```
