```elixir
defmodule Geodata.Address do
  @moduledoc """
  Value object representing a structured postal address.
  Provides construction, normalization, and validation without
  relying on raw primitive maps at domain boundaries.
  """

  @type country_code :: String.t()

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          region: String.t(),
          postal_code: String.t(),
          country_code: country_code()
        }

  @enforce_keys [:line1, :city, :region, :postal_code, :country_code]
  defstruct [:line1, :line2, :city, :region, :postal_code, :country_code]

  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(params) when is_map(params) do
    errors = collect_errors(params)

    if Enum.empty?(errors) do
      address = %__MODULE__{
        line1: String.trim(params[:line1] || ""),
        line2: normalize_optional(params[:line2]),
        city: String.trim(params[:city] || ""),
        region: String.trim(params[:region] || ""),
        postal_code: String.trim(params[:postal_code] || ""),
        country_code: String.upcase(String.trim(params[:country_code] || ""))
      }

      {:ok, address}
    else
      {:error, errors}
    end
  end

  @spec one_line(t()) :: String.t()
  def one_line(%__MODULE__{} = addr) do
    parts = [addr.line1, addr.line2, addr.city, addr.region, addr.postal_code, addr.country_code]
    parts |> Enum.reject(&is_nil/1) |> Enum.join(", ")
  end

  @spec same_country?(t(), t()) :: boolean()
  def same_country?(%__MODULE__{country_code: a}, %__MODULE__{country_code: b}), do: a == b

  @spec collect_errors(map()) :: [String.t()]
  defp collect_errors(params) do
    [
      blank_error(params[:line1], "line1"),
      blank_error(params[:city], "city"),
      blank_error(params[:region], "region"),
      blank_error(params[:postal_code], "postal_code"),
      country_code_error(params[:country_code])
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec blank_error(String.t() | nil, String.t()) :: String.t() | nil
  defp blank_error(value, field) do
    if is_nil(value) or String.trim(value) == "" do
      "#{field} is required"
    end
  end

  @spec country_code_error(String.t() | nil) :: String.t() | nil
  defp country_code_error(nil), do: "country_code is required"

  defp country_code_error(code) do
    unless String.match?(String.trim(code), ~r/^[A-Za-z]{2}$/) do
      "country_code must be a 2-letter ISO 3166-1 alpha-2 code"
    end
  end

  @spec normalize_optional(String.t() | nil) :: String.t() | nil
  defp normalize_optional(nil), do: nil
  defp normalize_optional(""), do: nil
  defp normalize_optional(val), do: String.trim(val)
end

defprotocol Geodata.Localizable do
  @moduledoc "Protocol for domain entities that carry a postal address."

  @doc "Returns the primary address of the entity."
  @spec primary_address(t()) :: Geodata.Address.t()
  def primary_address(entity)

  @doc "Returns a short location label suitable for display."
  @spec location_label(t()) :: String.t()
  def location_label(entity)
end

defmodule Geodata.Warehouse do
  @moduledoc "Represents a physical warehouse facility."

  alias Geodata.{Address, Localizable}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          address: Address.t(),
          capacity_units: non_neg_integer()
        }

  @enforce_keys [:id, :name, :address, :capacity_units]
  defstruct [:id, :name, :address, :capacity_units]

  defimpl Localizable do
    def primary_address(%Geodata.Warehouse{address: address}), do: address

    def location_label(%Geodata.Warehouse{name: name, address: addr}) do
      "#{name} (#{addr.city}, #{addr.country_code})"
    end
  end
end

defmodule Geodata.Supplier do
  @moduledoc "Represents a product supplier with a registered address."

  alias Geodata.{Address, Localizable}

  @type t :: %__MODULE__{
          id: String.t(),
          company_name: String.t(),
          registered_address: Address.t()
        }

  @enforce_keys [:id, :company_name, :registered_address]
  defstruct [:id, :company_name, :registered_address]

  defimpl Localizable do
    def primary_address(%Geodata.Supplier{registered_address: address}), do: address

    def location_label(%Geodata.Supplier{company_name: name, registered_address: addr}) do
      "#{name} — #{addr.city}, #{addr.region}"
    end
  end
end
```
