```elixir
defmodule Logistics.Address do
  @moduledoc """
  A validated shipping address represented as an immutable domain struct.
  Construction always goes through `new/1` to enforce field constraints
  at the boundary.
  """

  @enforce_keys [:line1, :city, :country_code, :postal_code]
  defstruct [:line1, :line2, :city, :state, :country_code, :postal_code]

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state: String.t() | nil,
          country_code: String.t(),
          postal_code: String.t()
        }

  @type field_error :: %{field: atom(), message: String.t()}

  @spec new(map()) :: {:ok, t()} | {:error, list(field_error())}
  def new(attrs) when is_map(attrs) do
    errors =
      []
      |> require_string(:line1, attrs)
      |> require_string(:city, attrs)
      |> require_string(:postal_code, attrs)
      |> validate_country_code(attrs)
      |> validate_max_length(:line1, 100, attrs)
      |> validate_max_length(:city, 60, attrs)
      |> validate_max_length(:postal_code, 20, attrs)

    if Enum.empty?(errors) do
      address = %__MODULE__{
        line1: fetch!(attrs, :line1),
        line2: Map.get(attrs, :line2),
        city: fetch!(attrs, :city),
        state: Map.get(attrs, :state),
        country_code: attrs |> fetch!(:country_code) |> String.upcase(),
        postal_code: fetch!(attrs, :postal_code)
      }

      {:ok, address}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = address) do
    [address.line1, address.line2, address.city, address.state,
     address.postal_code, address.country_code]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  @spec same_country?(t(), t()) :: boolean()
  def same_country?(%__MODULE__{country_code: c1}, %__MODULE__{country_code: c2}), do: c1 == c2

  @spec domestic?(t(), String.t()) :: boolean()
  def domestic?(%__MODULE__{country_code: code}, home_country)
      when is_binary(home_country) do
    code == String.upcase(home_country)
  end

  defp require_string(errors, field, attrs) do
    case Map.get(attrs, field) do
      value when is_binary(value) and byte_size(value) > 0 -> errors
      _ -> [%{field: field, message: "is required"} | errors]
    end
  end

  defp validate_country_code(errors, attrs) do
    case Map.get(attrs, :country_code) do
      code when is_binary(code) and byte_size(code) == 2 -> errors
      _ -> [%{field: :country_code, message: "must be a 2-letter ISO 3166-1 alpha-2 code"} | errors]
    end
  end

  defp validate_max_length(errors, field, max, attrs) do
    value = Map.get(attrs, field, "")
    if is_binary(value) and String.length(value) <= max do
      errors
    else
      [%{field: field, message: "must be #{max} characters or fewer"} | errors]
    end
  end

  defp fetch!(attrs, key), do: Map.fetch!(attrs, key)
end
```
