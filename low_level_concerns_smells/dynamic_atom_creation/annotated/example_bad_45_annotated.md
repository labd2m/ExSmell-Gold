# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `resolve_engine/1` function
- **Affected function(s):** `resolve_engine/1`
- **Short explanation:** The function converts the report engine identifier string stored in the database (and originally submitted by an admin) into an atom using `String.to_atom/1`. Engine identifiers are free-form strings in the reports configuration table, meaning any value inserted by an admin becomes a permanent atom at runtime.

---

```elixir
defmodule Reporting.ReportRunner do
  @moduledoc """
  Executes scheduled and on-demand reports using the configured rendering
  engine for each report definition. Stores results and notifies recipients.
  """

  require Logger

  alias Reporting.{ReportRepo, ResultStore, EngineRegistry, RecipientMailer}

  @timeout_ms 120_000

  @spec run(String.t()) :: {:ok, map()} | {:error, term()}
  def run(report_id) do
    Logger.info("Running report", report_id: report_id)

    with {:ok, report_def} <- ReportRepo.get_definition(report_id),
         {:ok, engine} <- resolve_engine(report_def.engine_name),
         {:ok, module} <- EngineRegistry.lookup(engine),
         {:ok, raw_data} <- fetch_report_data(report_def),
         {:ok, rendered} <- render_report(module, report_def, raw_data),
         {:ok, result} <- ResultStore.save(report_id, rendered),
         :ok <- notify_recipients(report_def, result) do
      Logger.info("Report completed", report_id: report_id, engine: engine)
      {:ok, result}
    else
      {:error, :engine_not_found} = err ->
        Logger.error("Unknown report engine", report_id: report_id)
        err

      {:error, reason} = err ->
        Logger.error("Report run failed", report_id: report_id, reason: inspect(reason))
        err
    end
  end

  @spec run_batch([String.t()]) :: {:ok, map()} | {:error, term()}
  def run_batch(report_ids) when is_list(report_ids) do
    Logger.info("Running report batch", count: length(report_ids))

    results =
      report_ids
      |> Task.async_stream(&run/1, timeout: @timeout_ms, on_timeout: :kill_task)
      |> Enum.reduce(%{ok: 0, failed: 0}, fn
        {:ok, {:ok, _}}, acc -> Map.update!(acc, :ok, &(&1 + 1))
        _, acc -> Map.update!(acc, :failed, &(&1 + 1))
      end)

    {:ok, results}
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is called on the
  # engine name string read from the database. Engine names are stored by
  # administrators through a configuration UI as free-form strings. Each
  # distinct value that has ever been saved (including typos, old engine names,
  # test values) creates a permanent atom. As the system is maintained and
  # engines are renamed or added, the atom table accumulates entries the
  # developer cannot predict or bound.
  defp resolve_engine(name) when is_binary(name) do
    engine = String.to_atom(name)
    {:ok, engine}
  end
  # VALIDATION: SMELL END

  defp resolve_engine(nil), do: {:error, :missing_engine_name}
  defp resolve_engine(_), do: {:error, :invalid_engine_name}

  defp fetch_report_data(%{data_source: source, parameters: params}) do
    case source do
      "sql" -> execute_sql_report(params)
      "api" -> fetch_api_report(params)
      "file" -> read_file_report(params)
      _ -> {:error, {:unknown_data_source, source}}
    end
  end

  defp execute_sql_report(%{"query" => query, "connection" => conn_name}) do
    Reporting.SQLExecutor.run(query, connection: conn_name)
  end

  defp execute_sql_report(_), do: {:error, :invalid_sql_params}

  defp fetch_api_report(%{"url" => url, "auth" => auth}) do
    Reporting.APIFetcher.fetch(url, auth: auth)
  end

  defp fetch_api_report(_), do: {:error, :invalid_api_params}

  defp read_file_report(%{"path" => path}) do
    Reporting.FileReader.read(path)
  end

  defp read_file_report(_), do: {:error, :invalid_file_params}

  defp render_report(module, report_def, data) do
    apply(module, :render, [report_def, data])
  rescue
    e -> {:error, {:render_failed, Exception.message(e)}}
  end

  defp notify_recipients(%{recipients: recipients}, result) when is_list(recipients) do
    Enum.each(recipients, &RecipientMailer.deliver(&1, result))
    :ok
  end

  defp notify_recipients(_, _), do: :ok
end
```
