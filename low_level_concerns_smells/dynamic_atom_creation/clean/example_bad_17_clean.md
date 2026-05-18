```elixir
defmodule MyApp.GraphQL.InputCoercer do
  @moduledoc """
  Provides type coercion helpers for GraphQL scalar and enum input values.
  Used by Absinthe custom scalar implementations and input object resolvers.
  """

  require Logger

  @currency_codes ~w(USD EUR GBP JPY AUD CAD CHF CNY SEK NZD)
  @sort_directions ~w(asc desc)
  @order_statuses ~w(pending confirmed processing shipped delivered cancelled refunded)
  @user_roles ~w(admin editor viewer guest)

  @doc """
  Coerces a raw string into a validated currency code atom.
  """
  @spec coerce_currency(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def coerce_currency(raw) when is_binary(raw) do
    upcased = String.upcase(raw)

    if upcased in @currency_codes do
      {:ok, String.to_atom(upcased)}
    else
      {:error, "Invalid currency code: #{raw}"}
    end
  end

  def coerce_currency(_), do: {:error, "Currency must be a string"}

  @doc """
  Coerces a raw string into a sort direction atom.
  """
  @spec coerce_sort_direction(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def coerce_sort_direction(raw) when is_binary(raw) do
    lowered = String.downcase(raw)

    if lowered in @sort_directions do
      {:ok, String.to_atom(lowered)}
    else
      {:error, "Sort direction must be 'asc' or 'desc'"}
    end
  end

  def coerce_sort_direction(_), do: {:error, "Sort direction must be a string"}

  @doc """
  Generic enum coercion used by Absinthe enum scalar parse callbacks.
  Converts an incoming string value to the atom representation of the
  enum variant declared in the schema.
  """
  @spec coerce_enum(String.t(), [String.t()]) :: {:ok, atom()} | {:error, String.t()}
  def coerce_enum(raw, valid_values) when is_binary(raw) and is_list(valid_values) do
    if raw in valid_values do
      {:ok, String.to_atom(raw)}
    else
      {:error, "Expected one of: #{Enum.join(valid_values, ", ")}. Got: #{raw}"}
    end
  end

  def coerce_enum(_, _), do: {:error, "Enum value must be a string"}

  @doc """
  Coerces an order status string.
  """
  @spec coerce_order_status(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def coerce_order_status(raw) when is_binary(raw) do
    coerce_enum(raw, @order_statuses)
  end

  @doc """
  Coerces a user role string.
  """
  @spec coerce_user_role(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def coerce_user_role(raw) when is_binary(raw) do
    coerce_enum(raw, @user_roles)
  end

  @doc """
  Coerces a raw ID string, typically provided as a base64-encoded global ID.
  Returns the decoded integer or string ID.
  """
  @spec coerce_id(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def coerce_id(raw) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [_type, id] -> {:ok, id}
          _ -> {:ok, raw}
        end

      :error ->
        {:ok, raw}
    end
  end

  def coerce_id(_), do: {:error, "ID must be a string"}

  @doc """
  Coerces an ISO8601 datetime string.
  """
  @spec coerce_datetime(String.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def coerce_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, "Invalid ISO8601 datetime: #{raw}"}
    end
  end

  def coerce_datetime(_), do: {:error, "Datetime must be a string"}
end
```
