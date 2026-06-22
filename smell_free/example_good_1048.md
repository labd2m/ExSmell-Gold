```elixir
defprotocol Reporting.Serializable do
  @moduledoc """
  Protocol for converting domain structs into serializable report representations.
  Implementing this protocol ensures every reportable entity can produce
  a normalized map suitable for CSV, JSON, or PDF rendering.
  """

  @doc "Converts the struct into a flat map of report fields."
  @spec to_report_row(t()) :: map()
  def to_report_row(entity)

  @doc "Returns the ordered list of column headers for this entity type."
  @spec column_headers(t()) :: [String.t()]
  def column_headers(entity)
end

defmodule Reporting.Entities.SalesOrder do
  @moduledoc "Represents a completed sales order for reporting purposes."

  @enforce_keys [:id, :customer_name, :total_cents, :currency, :placed_at]
  defstruct [:id, :customer_name, :total_cents, :currency, :placed_at, :status]

  @type t :: %__MODULE__{
          id: String.t(),
          customer_name: String.t(),
          total_cents: non_neg_integer(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: :pending | :fulfilled | :cancelled
        }
end

defimpl Reporting.Serializable, for: Reporting.Entities.SalesOrder do
  @moduledoc false

  def to_report_row(%Reporting.Entities.SalesOrder{} = order) do
    %{
      "order_id" => order.id,
      "customer" => order.customer_name,
      "total" => format_currency(order.total_cents, order.currency),
      "status" => Atom.to_string(order.status),
      "placed_at" => DateTime.to_iso8601(order.placed_at)
    }
  end

  def column_headers(%Reporting.Entities.SalesOrder{}) do
    ["order_id", "customer", "total", "status", "placed_at"]
  end

  defp format_currency(cents, currency) do
    amount = cents / 100
    "#{currency} #{:erlang.float_to_binary(amount, decimals: 2)}"
  end
end

defmodule Reporting.Entities.StaffMember do
  @moduledoc "Represents a staff member record for reporting purposes."

  @enforce_keys [:id, :full_name, :department, :hire_date]
  defstruct [:id, :full_name, :department, :hire_date, :role]

  @type t :: %__MODULE__{
          id: String.t(),
          full_name: String.t(),
          department: String.t(),
          hire_date: Date.t(),
          role: String.t() | nil
        }
end

defimpl Reporting.Serializable, for: Reporting.Entities.StaffMember do
  @moduledoc false

  def to_report_row(%Reporting.Entities.StaffMember{} = member) do
    %{
      "staff_id" => member.id,
      "name" => member.full_name,
      "department" => member.department,
      "role" => member.role || "N/A",
      "hire_date" => Date.to_iso8601(member.hire_date)
    }
  end

  def column_headers(%Reporting.Entities.StaffMember{}) do
    ["staff_id", "name", "department", "role", "hire_date"]
  end
end

defmodule Reporting.CsvRenderer do
  @moduledoc """
  Renders a list of `Reporting.Serializable` entities into a CSV binary.
  The column order is determined by the first entity in the list.
  """

  alias Reporting.Serializable

  @doc """
  Produces a CSV string from a list of serializable entities.
  Returns an empty string for an empty list.
  """
  @spec render([Serializable.t()]) :: String.t()
  def render([]), do: ""

  def render([first | _] = entities) do
    headers = Serializable.column_headers(first)
    rows = Enum.map(entities, &entity_to_row(&1, headers))

    [headers | rows]
    |> Enum.map(&Enum.join(&1, ","))
    |> Enum.join("\n")
  end

  @spec entity_to_row(Serializable.t(), [String.t()]) :: [String.t()]
  defp entity_to_row(entity, headers) do
    row_map = Serializable.to_report_row(entity)
    Enum.map(headers, fn h -> Map.get(row_map, h, "") end)
  end
end
```
