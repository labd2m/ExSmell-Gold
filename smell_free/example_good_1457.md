```elixir
defprotocol Exportable do
  @moduledoc """
  Protocol for converting domain structs into export-ready map representations.
  Any struct implementing this protocol can be serialized uniformly
  by the reporting pipeline.
  """

  @doc "Converts a struct to a plain map suitable for JSON or CSV export."
  @spec to_export_map(t()) :: map()
  def to_export_map(value)
end

defmodule Reports.Invoice do
  @moduledoc """
  Represents a finalized billing invoice.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          customer_email: String.t(),
          amount_cents: non_neg_integer(),
          issued_on: Date.t(),
          status: :pending | :paid | :void
        }

  defstruct [:id, :customer_email, :amount_cents, :issued_on, :status]
end

defmodule Reports.Subscription do
  @moduledoc """
  Represents an active or cancelled subscription record.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          plan: String.t(),
          subscriber_email: String.t(),
          started_on: Date.t(),
          cancelled_on: Date.t() | nil
        }

  defstruct [:id, :plan, :subscriber_email, :started_on, :cancelled_on]
end

defimpl Exportable, for: Reports.Invoice do
  def to_export_map(invoice) do
    %{
      id: invoice.id,
      type: "invoice",
      customer_email: invoice.customer_email,
      amount_cents: invoice.amount_cents,
      issued_on: Date.to_iso8601(invoice.issued_on),
      status: Atom.to_string(invoice.status)
    }
  end
end

defimpl Exportable, for: Reports.Subscription do
  def to_export_map(subscription) do
    %{
      id: subscription.id,
      type: "subscription",
      plan: subscription.plan,
      subscriber_email: subscription.subscriber_email,
      started_on: Date.to_iso8601(subscription.started_on),
      cancelled_on: format_optional_date(subscription.cancelled_on)
    }
  end

  defp format_optional_date(nil), do: nil
  defp format_optional_date(date), do: Date.to_iso8601(date)
end

defmodule Reports.Exporter do
  @moduledoc """
  Produces a uniform list of export maps from any collection of
  `Exportable`-implementing structs.
  """

  @spec export_all([Exportable.t()]) :: [map()]
  def export_all(records) when is_list(records) do
    Enum.map(records, &Exportable.to_export_map/1)
  end

  @spec export_to_json([Exportable.t()]) :: {:ok, String.t()} | {:error, term()}
  def export_to_json(records) when is_list(records) do
    records
    |> export_all()
    |> Jason.encode()
  end
end
```
