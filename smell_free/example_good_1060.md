**File:** `example_good_1060.md`

```elixir
defprotocol Reports.Exportable do
  @moduledoc """
  Protocol enabling domain structs to declare their own serialization
  strategies for report exports. Implementors provide a header row and
  a row-data function, keeping export logic co-located with the type.
  """

  @doc "Returns a list of column header strings for CSV/XLSX export."
  @spec headers(t()) :: [String.t()]
  def headers(value)

  @doc "Returns a list of stringified cell values matching the header order."
  @spec to_row(t()) :: [String.t()]
  def to_row(value)

  @doc "Returns a human-readable display label for the record."
  @spec label(t()) :: String.t()
  def label(value)
end

defmodule Reports.Invoice do
  @moduledoc "Invoice domain struct with export support."

  @enforce_keys [:id, :number, :amount_cents, :currency, :status, :issued_at]
  defstruct [:id, :number, :amount_cents, :currency, :status, :issued_at, :due_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          number: String.t(),
          amount_cents: integer(),
          currency: String.t(),
          status: :draft | :sent | :paid | :overdue,
          issued_at: Date.t(),
          due_at: Date.t() | nil
        }
end

defimpl Reports.Exportable, for: Reports.Invoice do
  def headers(_invoice) do
    ["Invoice #", "Status", "Amount", "Currency", "Issued", "Due"]
  end

  def to_row(invoice) do
    [
      invoice.number,
      Atom.to_string(invoice.status),
      format_amount(invoice.amount_cents),
      String.upcase(invoice.currency),
      Date.to_string(invoice.issued_at),
      format_due_date(invoice.due_at)
    ]
  end

  def label(invoice), do: "Invoice #{invoice.number}"

  defp format_amount(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2)
  defp format_due_date(nil), do: ""
  defp format_due_date(date), do: Date.to_string(date)
end

defmodule Reports.Customer do
  @moduledoc "Customer domain struct with export support."

  @enforce_keys [:id, :name, :email, :plan, :joined_at]
  defstruct [:id, :name, :email, :plan, :joined_at, :country]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          email: String.t(),
          plan: String.t(),
          joined_at: Date.t(),
          country: String.t() | nil
        }
end

defimpl Reports.Exportable, for: Reports.Customer do
  def headers(_customer), do: ["Name", "Email", "Plan", "Country", "Joined"]

  def to_row(customer) do
    [
      customer.name,
      customer.email,
      customer.plan,
      customer.country || "N/A",
      Date.to_string(customer.joined_at)
    ]
  end

  def label(customer), do: customer.name
end

defmodule Reports.CsvExporter do
  @moduledoc """
  Converts any list of `Exportable`-implementing structs into a CSV binary.
  Assumes a homogeneous list (all elements share the same type).
  """

  alias Reports.Exportable

  @spec export([Exportable.t()]) :: {:ok, binary()} | {:error, :empty_list}
  def export([first | _] = records) do
    headers = Exportable.headers(first)
    rows = Enum.map(records, &Exportable.to_row/1)
    csv = build_csv([headers | rows])
    {:ok, csv}
  end

  def export([]) do
    {:error, :empty_list}
  end

  defp build_csv(rows) do
    rows
    |> Enum.map(&encode_row/1)
    |> Enum.join("\n")
  end

  defp encode_row(cells) do
    cells
    |> Enum.map(&escape_cell/1)
    |> Enum.join(",")
  end

  defp escape_cell(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      ~s("#{String.replace(value, "\"", "\"\"")}")
    else
      value
    end
  end
end
```
