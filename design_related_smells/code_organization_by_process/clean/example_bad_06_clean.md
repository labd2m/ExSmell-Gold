```elixir
defmodule Reporting.ReportFormatter do
  use GenServer

  @moduledoc """
  Provides formatting utilities for financial and operational reports.
  Converts raw data maps into CSV rows, summary lines, and human-readable
  monetary and percentage strings for use in generated report files and
  dashboard views.
  """

  @default_opts %{
    currency_symbol: "$",
    decimal_separator: ".",
    thousands_separator: ",",
    percent_decimals: 2,
    max_label_length: 40,
    date_format: "{YYYY}-{0M}-{0D}"
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {fmt_opts, gen_opts} = Keyword.split(opts, Map.keys(@default_opts) |> Enum.map(&to_atom/1))
    merged = Map.merge(@default_opts, Map.new(fmt_opts))
    GenServer.start_link(__MODULE__, merged, gen_opts)
  end




  @doc """
  Converts a report data map into a CSV-formatted row string.
  `fields` is an ordered list of keys to extract from `row_map`.
  """
  def to_csv_row(pid, row_map, fields) do
    GenServer.call(pid, {:to_csv_row, row_map, fields})
  end

  @doc """
  Formats a summary map as a single human-readable line for report headers.
  """
  def to_summary_line(pid, summary_map) do
    GenServer.call(pid, {:to_summary_line, summary_map})
  end

  @doc "Formats a numeric amount as a currency string."
  def format_currency(pid, amount) do
    GenServer.call(pid, {:format_currency, amount})
  end

  @doc "Formats a ratio (0.0–1.0) as a percentage string."
  def format_percentage(pid, ratio) do
    GenServer.call(pid, {:format_percentage, ratio})
  end

  @doc "Truncates a label string to the configured max length."
  def truncate_label(pid, label, suffix \\ "...") do
    GenServer.call(pid, {:truncate_label, label, suffix})
  end
  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call({:to_csv_row, row_map, fields}, _from, opts) do
    row =
      fields
      |> Enum.map(fn key ->
        value = Map.get(row_map, key, "")
        value |> to_string() |> csv_escape()
      end)
      |> Enum.join(",")

    {:reply, {:ok, row}, opts}
  end

  @impl true
  def handle_call({:to_summary_line, summary}, _from, opts) do
    line =
      summary
      |> Enum.map(fn {k, v} -> "#{humanize(k)}: #{v}" end)
      |> Enum.join(" | ")

    {:reply, {:ok, line}, opts}
  end

  @impl true
  def handle_call({:format_currency, amount}, _from, opts) do
    formatted = do_format_currency(amount, opts)
    {:reply, {:ok, formatted}, opts}
  end

  @impl true
  def handle_call({:format_percentage, ratio}, _from, opts) do
    pct = Float.round(ratio * 100.0, opts.percent_decimals)
    {:reply, {:ok, "#{pct}%"}, opts}
  end

  @impl true
  def handle_call({:truncate_label, label, suffix}, _from, opts) do
    truncated =
      if String.length(label) > opts.max_label_length do
        cut = opts.max_label_length - String.length(suffix)
        String.slice(label, 0, cut) <> suffix
      else
        label
      end

    {:reply, {:ok, truncated}, opts}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_format_currency(amount, opts) when is_float(amount) or is_integer(amount) do
    rounded = Float.round(amount / 1.0, 2)
    [int_part, dec_part] = :erlang.float_to_binary(rounded, decimals: 2) |> String.split(".")
    int_formatted = int_part |> String.to_charlist() |> Enum.reverse()
      |> Enum.chunk_every(3) |> Enum.join(opts.thousands_separator)
      |> String.reverse()
    "#{opts.currency_symbol}#{int_formatted}#{opts.decimal_separator}#{dec_part}"
  end

  defp csv_escape(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      ~s("#{String.replace(value, "\"", "\"\"")}")
    else
      value
    end
  end

  defp humanize(key) when is_atom(key) do
    key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize(key), do: to_string(key)

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key), do: String.to_atom(to_string(key))
end
```
