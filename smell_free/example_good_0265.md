```elixir
defmodule Reports.Builder do
  @moduledoc """
  Assembles structured reports from configurable data sources and
  formatters. Each report configuration is expressed as a plain struct,
  keeping the builder itself stateless and easy to test in isolation.
  Data fetching, aggregation, and rendering are each delegated to
  dedicated modules, making individual steps independently replaceable.
  """

  alias Reports.{Aggregator, DataSource, Formatter, ReportConfig, Section}

  @type build_result ::
          {:ok, %{title: String.t(), sections: [Section.t()], generated_at: DateTime.t()}}
          | {:error, term()}

  @doc """
  Builds a report from a `ReportConfig` struct. Fetches raw data for each
  section, runs the configured aggregation, and renders the result through
  the specified formatter.
  Returns `{:ok, report}` or `{:error, reason}`.
  """
  @spec build(ReportConfig.t()) :: build_result()
  def build(%ReportConfig{} = config) do
    with {:ok, raw_sections} <- fetch_all_sections(config),
         {:ok, aggregated} <- aggregate_sections(raw_sections, config),
         {:ok, rendered} <- render(aggregated, config.formatter) do
      {:ok, %{title: config.title, sections: rendered, generated_at: DateTime.utc_now()}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private pipeline steps
  # ---------------------------------------------------------------------------

  defp fetch_all_sections(%ReportConfig{sections: section_configs, date_range: range}) do
    results =
      Enum.map(section_configs, fn section_cfg ->
        with {:ok, data} <- DataSource.fetch(section_cfg.source, range) do
          {:ok, %{config: section_cfg, raw_data: data}}
        end
      end)

    collect_results(results)
  end

  defp aggregate_sections(raw_sections, %ReportConfig{aggregation: agg_config}) do
    results =
      Enum.map(raw_sections, fn %{config: cfg, raw_data: data} ->
        with {:ok, aggregated_data} <- Aggregator.run(data, agg_config) do
          {:ok, %Section{title: cfg.title, data: aggregated_data, metadata: cfg.metadata}}
        end
      end)

    collect_results(results)
  end

  defp render(sections, formatter_module) when is_atom(formatter_module) do
    results = Enum.map(sections, &formatter_module.render_section/1)
    collect_results(results)
  end

  defp collect_results(results) do
    {oks, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    case errors do
      [] -> {:ok, Enum.map(oks, fn {:ok, val} -> val end)}
      [{:error, reason} | _] -> {:error, reason}
    end
  end
end

defmodule Reports.ReportConfig do
  @moduledoc """
  Configuration struct for a single report run. Encapsulates the title,
  section definitions, date range, aggregation settings, and the formatter
  module to use when rendering output.
  """

  @enforce_keys [:title, :sections, :date_range, :aggregation, :formatter]
  defstruct [:title, :sections, :date_range, :aggregation, :formatter]

  @type date_range :: {Date.t(), Date.t()}

  @type t :: %__MODULE__{
          title: String.t(),
          sections: [map()],
          date_range: date_range(),
          aggregation: map(),
          formatter: module()
        }
end

defmodule Reports.Section do
  @moduledoc """
  Represents a single rendered section within a report.
  """

  @enforce_keys [:title, :data]
  defstruct [:title, :data, metadata: %{}]

  @type t :: %__MODULE__{
          title: String.t(),
          data: term(),
          metadata: map()
        }
end

defmodule Reports.Formatters.Json do
  @moduledoc """
  Renders a report section as a JSON-compatible map.
  """

  @spec render_section(Reports.Section.t()) :: {:ok, map()} | {:error, term()}
  def render_section(%Reports.Section{title: title, data: data, metadata: meta}) do
    {:ok, %{"title" => title, "data" => data, "metadata" => meta}}
  end
end

defmodule Reports.Formatters.PlainText do
  @moduledoc """
  Renders a report section as a plain-text string for email delivery.
  """

  @spec render_section(Reports.Section.t()) :: {:ok, String.t()} | {:error, term()}
  def render_section(%Reports.Section{title: title, data: data}) do
    rendered = "## #{title}\n\n#{inspect(data, pretty: true)}\n"
    {:ok, rendered}
  end
end
```
