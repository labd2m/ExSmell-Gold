```elixir
defmodule Reporting.ParallelGenerator do
  @moduledoc """
  Generates multi-section reports by running each section concurrently
  under a `Task.Supervisor`.

  Section failures are captured individually; a failure in one section does
  not prevent other sections from completing. The final report includes a
  failure summary.
  """

  @type section_spec :: %{
          name: atom(),
          module: module(),
          params: map()
        }

  @type section_result :: %{
          name: atom(),
          status: :ok | :error,
          data: term()
        }

  @type report :: %{
          generated_at: String.t(),
          sections: [section_result()],
          total: non_neg_integer(),
          failed: non_neg_integer()
        }

  @default_timeout 15_000

  @doc """
  Concurrently generates all sections specified in `specs`.

  Each spec must have a `:module` implementing `generate/1` and a `:params` map.
  Returns a structured report regardless of individual section failures.
  """
  @spec generate(Supervisor.supervisor(), [section_spec()], keyword()) :: report()
  def generate(task_sup, specs, opts \\ []) when is_list(specs) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    results =
      specs
      |> Task.Supervisor.async_stream_nolink(
        task_sup,
        &run_section/1,
        max_concurrency: max(length(specs), 1),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(specs)
      |> Enum.map(&build_section_result/1)

    assemble(results)
  end

  defp run_section(%{module: module, params: params}) do
    module.generate(params)
  end

  defp build_section_result({{:ok, {:ok, data}}, %{name: name}}) do
    %{name: name, status: :ok, data: data}
  end

  defp build_section_result({{:ok, {:error, reason}}, %{name: name}}) do
    %{name: name, status: :error, data: reason}
  end

  defp build_section_result({{:exit, reason}, %{name: name}}) do
    %{name: name, status: :error, data: {:exit, reason}}
  end

  defp assemble(results) do
    %{
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      sections: results,
      total: length(results),
      failed: Enum.count(results, &(&1.status == :error))
    }
  end
end

defmodule Reporting.SalesSection do
  @moduledoc """
  Generates the sales summary section for inclusion in a parallel report.
  """

  @type params :: %{
          required(:account_id) => pos_integer(),
          required(:from) => Date.t(),
          required(:to) => Date.t()
        }

  @type result :: %{
          period_days: non_neg_integer(),
          total_revenue_cents: non_neg_integer(),
          order_count: non_neg_integer()
        }

  @doc "Generates sales data for a given account and date range."
  @spec generate(params()) :: {:ok, result()} | {:error, term()}
  def generate(%{account_id: account_id, from: from, to: to})
      when is_integer(account_id) and account_id > 0 do
    days = Date.diff(to, from)

    if days < 0 do
      {:error, :invalid_date_range}
    else
      {:ok, %{period_days: days, total_revenue_cents: 0, order_count: 0}}
    end
  end

  def generate(_params), do: {:error, :invalid_params}
end
```
