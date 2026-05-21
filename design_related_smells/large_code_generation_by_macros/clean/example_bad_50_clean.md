```elixir
defmodule MyApp.Reporting.ColumnRegistry do
  @moduledoc """
  DSL for declaring typed, formatted columns in data report definitions.

  Each `column/3` call registers a named field with its data type, aggregation
  strategy, and display format. The module automatically generates per-column
  extraction and formatting helpers.

  ## Usage

      defmodule MyApp.Reporting.InvoiceSummaryReport do
        use MyApp.Reporting.ColumnRegistry

        column :invoice_number, :string,  aggregate: :none,  format: :plain,    width: 20
        column :issued_at,      :date,    aggregate: :none,  format: :iso8601,  width: 12
        column :customer_name,  :string,  aggregate: :none,  format: :plain,    width: 30
        column :subtotal,       :decimal, aggregate: :sum,   format: :currency, width: 14
        column :tax,            :decimal, aggregate: :sum,   format: :currency, width: 10
        column :total,          :decimal, aggregate: :sum,   format: :currency, width: 14
        column :status,         :string,  aggregate: :count, format: :plain,    width: 12
      end
  """

  @valid_types      [:string, :integer, :decimal, :float, :date, :datetime, :boolean]
  @valid_aggregates [:none, :sum, :avg, :count, :min, :max]
  @valid_formats    [:plain, :currency, :percentage, :iso8601, :short_date, :boolean_label]
  @max_width        120
  @min_width        4

  defmacro __using__(_opts) do
    quote do
      import MyApp.Reporting.ColumnRegistry, only: [column: 3]
      Module.register_attribute(__MODULE__, :report_columns, accumulate: true)
      @before_compile MyApp.Reporting.ColumnRegistry
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns all column definitions in declaration order."
      def columns, do: Enum.reverse(@report_columns)

      @doc "Returns column names in declaration order."
      def column_names, do: @report_columns |> Enum.reverse() |> Enum.map(&elem(&1, 0))

      @doc "Extracts and formats all column values from a single data row map."
      def format_row(row) when is_map(row) do
        Map.new(@report_columns, fn {name, _type, _opts} ->
          raw  = apply(__MODULE__, :"extract_#{name}", [row])
          cell = apply(__MODULE__, :"format_#{name}", [raw])
          {name, cell}
        end)
      end
    end
  end

  defmacro column(name, type, opts \\ []) do
    quote do
      unless is_atom(unquote(name)) do
        raise ArgumentError,
              "column/3: column name must be an atom, got: #{inspect(unquote(name))}"
      end

      unless unquote(type) in unquote(@valid_types) do
        raise ArgumentError,
              "column/3 #{inspect(unquote(name))}: unknown type #{inspect(unquote(type))}. " <>
                "Valid types: #{inspect(unquote(@valid_types))}"
      end

      aggregate = Keyword.get(unquote(opts), :aggregate, :none)
      format    = Keyword.get(unquote(opts), :format, :plain)
      width     = Keyword.get(unquote(opts), :width, 20)

      unless aggregate in unquote(@valid_aggregates) do
        raise ArgumentError,
              "column/3 #{inspect(unquote(name))}: unknown aggregate #{inspect(aggregate)}. " <>
                "Valid aggregates: #{inspect(unquote(@valid_aggregates))}"
      end

      unless format in unquote(@valid_formats) do
        raise ArgumentError,
              "column/3 #{inspect(unquote(name))}: unknown format #{inspect(format)}. " <>
                "Valid formats: #{inspect(unquote(@valid_formats))}"
      end

      unless is_integer(width) and width >= unquote(@min_width) and width <= unquote(@max_width) do
        raise ArgumentError,
              "column/3 #{inspect(unquote(name))}: :width must be an integer between " <>
                "#{unquote(@min_width)} and #{unquote(@max_width)}, got: #{inspect(width)}"
      end

      @report_columns {unquote(name), unquote(type),
                       [aggregate: aggregate, format: format, width: width]}

      def unquote(:"extract_#{name}")(row) do
        raw = Map.get(row, unquote(name))

        case unquote(type) do
          :decimal -> if is_binary(raw), do: Decimal.new(raw), else: raw
          :date    -> if is_binary(raw), do: Date.from_iso8601!(raw), else: raw
          _        -> raw
        end
      end

      def unquote(:"format_#{name}")(value) do
        case format do
          :currency      -> "$#{:erlang.float_to_binary(value / 1.0, decimals: 2)}"
          :percentage    -> "#{value}%"
          :iso8601       -> if is_nil(value), do: "", else: to_string(value)
          :boolean_label -> if value, do: "Yes", else: "No"
          _              -> to_string(value || "")
        end
      end

      def unquote(:"column_#{name}_meta")() do
        %{name: unquote(name), type: unquote(type), aggregate: aggregate,
          format: format, width: width}
      end
    end
  end

  @doc "Returns all valid column data types."
  def valid_types, do: @valid_types

  @doc "Returns all valid aggregate functions."
  def valid_aggregates, do: @valid_aggregates
end
```
