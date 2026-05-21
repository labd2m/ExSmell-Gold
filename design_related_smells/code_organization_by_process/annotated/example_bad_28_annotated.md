# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Imports.RowValidator` module
- **Affected function(s)**: `validate/3`, `validate_all/3`, `errors/3`, `valid?/3`
- **Short explanation**: Row-level validation is a pure transformation of a map through a list of rule functions. Each call is completely independent and shares no state with any other call. The `GenServer` state carries only a compiled rule set that never changes at runtime. During a bulk CSV import of tens of thousands of rows, all row validation serializes through this one process—a bottleneck introduced solely by modeling stateless logic as a process.

## Code

```elixir
defmodule Imports.RowValidator do
  use GenServer

  @moduledoc """
  Validates individual rows parsed from CSV product import files.
  Used by the background import worker to produce per-row error reports
  before attempting database insertion.
  """

  @schema_rules %{
    product: [
      {:required, [:sku, :name, :price, :stock_qty]},
      {:format,   :sku,       ~r/^[A-Z0-9\-]{3,32}$/},
      {:type,     :price,     :decimal},
      {:range,    :price,     {0.0, 999_999.99}},
      {:type,     :stock_qty, :integer},
      {:range,    :stock_qty, {0, 1_000_000}},
      {:max_len,  :name,      255},
      {:max_len,  :description, 2000}
    ],
    customer: [
      {:required, [:email, :first_name, :last_name]},
      {:format,   :email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/},
      {:max_len,  :first_name, 100},
      {:max_len,  :last_name,  100},
      {:format,   :phone, ~r/^\+?[\d\s\-().]{7,20}$/}
    ],
    inventory: [
      {:required, [:warehouse_code, :sku, :quantity, :bin_location]},
      {:format,   :warehouse_code, ~r/^WH-\d{3}$/},
      {:format,   :sku,            ~r/^[A-Z0-9\-]{3,32}$/},
      {:type,     :quantity, :integer},
      {:range,    :quantity, {0, 100_000}},
      {:max_len,  :bin_location, 20}
    ]
  }

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because RowValidator uses a GenServer to organize
  # VALIDATION: a pure data-validation pipeline. The schema rules are a compile-time
  # VALIDATION: constant stored in the process state but never mutated. Each call
  # VALIDATION: receives a complete row map and returns validation results solely
  # VALIDATION: from that input and the static rule list. A 50 000-row CSV import
  # VALIDATION: that validates rows concurrently would bottleneck all validation
  # VALIDATION: through this one process, despite each row being fully independent.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, @schema_rules, opts)
  end

  @doc """
  Validates a single row map against the schema for `type`.
  Returns `{:ok, row}` or `{:error, errors}`.
  """
  def validate(pid, type, row) do
    GenServer.call(pid, {:validate, type, row})
  end

  @doc """
  Validates a list of rows and returns `{valid_rows, error_rows}`.
  `error_rows` is a list of `%{row: row, errors: [...]}` maps.
  """
  def validate_all(pid, type, rows) do
    GenServer.call(pid, {:validate_all, type, rows})
  end

  @doc """
  Returns only the list of error strings for a row (empty list if valid).
  """
  def errors(pid, type, row) do
    GenServer.call(pid, {:errors, type, row})
  end

  @doc """
  Returns `true` if the row passes all rules.
  """
  def valid?(pid, type, row) do
    GenServer.call(pid, {:valid, type, row})
  end

  ## GenServer Callbacks

  @impl true
  def init(rules), do: {:ok, rules}

  @impl true
  def handle_call({:validate, type, row}, _from, rules) do
    errs = run_rules(row, Map.get(rules, type, []))

    result =
      if errs == [],
        do: {:ok, row},
        else: {:error, errs}

    {:reply, result, rules}
  end

  @impl true
  def handle_call({:validate_all, type, rows}, _from, rules) do
    rule_set = Map.get(rules, type, [])

    {valid, invalid} =
      Enum.split_with(rows, fn row ->
        run_rules(row, rule_set) == []
      end)

    error_rows =
      Enum.map(invalid, fn row ->
        %{row: row, errors: run_rules(row, rule_set)}
      end)

    {:reply, {:ok, valid, error_rows}, rules}
  end

  @impl true
  def handle_call({:errors, type, row}, _from, rules) do
    errs = run_rules(row, Map.get(rules, type, []))
    {:reply, errs, rules}
  end

  @impl true
  def handle_call({:valid, type, row}, _from, rules) do
    {:reply, run_rules(row, Map.get(rules, type, [])) == [], rules}
  end

  # VALIDATION: SMELL END

  defp run_rules(row, rule_list) do
    Enum.flat_map(rule_list, &apply_rule(row, &1))
  end

  defp apply_rule(row, {:required, fields}) do
    Enum.flat_map(fields, fn field ->
      val = Map.get(row, field)
      if is_nil(val) or val == "",
        do: ["#{field} is required"],
        else: []
    end)
  end

  defp apply_rule(row, {:format, field, regex}) do
    val = Map.get(row, field, "")
    if val != "" and not Regex.match?(regex, to_string(val)),
      do: ["#{field} has an invalid format"],
      else: []
  end

  defp apply_rule(row, {:type, field, :integer}) do
    val = Map.get(row, field, "")
    case Integer.parse(to_string(val)) do
      {_, ""} -> []
      _ -> ["#{field} must be an integer"]
    end
  end

  defp apply_rule(row, {:type, field, :decimal}) do
    val = Map.get(row, field, "")
    case Float.parse(to_string(val)) do
      {_, ""} -> []
      _ -> ["#{field} must be a decimal number"]
    end
  end

  defp apply_rule(row, {:range, field, {min_val, max_val}}) do
    with val_str <- to_string(Map.get(row, field, "")),
         {num, ""} <- Float.parse(val_str) do
      if num >= min_val and num <= max_val,
        do: [],
        else: ["#{field} must be between #{min_val} and #{max_val}"]
    else
      _ -> []
    end
  end

  defp apply_rule(row, {:max_len, field, max}) do
    val = to_string(Map.get(row, field, ""))
    if String.length(val) > max,
      do: ["#{field} must not exceed #{max} characters"],
      else: []
  end

  defp apply_rule(_row, _unknown), do: []
end
```
