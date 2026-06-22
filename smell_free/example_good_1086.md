```elixir
defmodule Shipping.AddressValidator do
  @moduledoc """
  Validates and normalizes shipping addresses against carrier-specific
  formatting rules. Returns structured validation results with field-level diagnostics.
  """

  @type address :: %{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state_code: String.t(),
          postal_code: String.t(),
          country_code: String.t()
        }

  @type validation_result ::
          {:ok, address()}
          | {:error, %{field: atom(), reason: atom()}}

  @valid_country_codes ~w[US CA GB AU DE FR]

  @spec validate(map()) :: validation_result()
  def validate(raw) when is_map(raw) do
    with {:ok, address} <- cast_fields(raw),
         :ok <- validate_line1(address.line1),
         :ok <- validate_city(address.city),
         :ok <- validate_state_code(address.state_code),
         :ok <- validate_postal_code(address.postal_code, address.country_code),
         :ok <- validate_country_code(address.country_code) do
      {:ok, normalize(address)}
    end
  end

  @spec cast_fields(map()) :: {:ok, address()} | {:error, map()}
  defp cast_fields(raw) do
    required = [:line1, :city, :state_code, :postal_code, :country_code]

    missing = Enum.find(required, fn key -> not is_binary(Map.get(raw, key)) end)

    case missing do
      nil ->
        {:ok,
         %{
           line1: raw[:line1],
           line2: Map.get(raw, :line2),
           city: raw[:city],
           state_code: raw[:state_code],
           postal_code: raw[:postal_code],
           country_code: raw[:country_code]
         }}

      field ->
        {:error, %{field: field, reason: :required}}
    end
  end

  defp validate_line1(line1) when byte_size(line1) >= 3, do: :ok
  defp validate_line1(_), do: {:error, %{field: :line1, reason: :too_short}}

  defp validate_city(city) when byte_size(city) >= 2, do: :ok
  defp validate_city(_), do: {:error, %{field: :city, reason: :too_short}}

  defp validate_state_code(code) when byte_size(code) == 2, do: :ok
  defp validate_state_code(_), do: {:error, %{field: :state_code, reason: :invalid_format}}

  defp validate_country_code(code) when code in @valid_country_codes, do: :ok
  defp validate_country_code(_), do: {:error, %{field: :country_code, reason: :unsupported}}

  @spec validate_postal_code(String.t(), String.t()) :: :ok | {:error, map()}
  defp validate_postal_code(postal, "US") do
    if Regex.match?(~r/^\d{5}(-\d{4})?$/, postal) do
      :ok
    else
      {:error, %{field: :postal_code, reason: :invalid_format}}
    end
  end

  defp validate_postal_code(postal, "CA") do
    if Regex.match?(~r/^[A-Z]\d[A-Z] \d[A-Z]\d$/, postal) do
      :ok
    else
      {:error, %{field: :postal_code, reason: :invalid_format}}
    end
  end

  defp validate_postal_code(postal, _country) when byte_size(postal) >= 3, do: :ok
  defp validate_postal_code(_, _), do: {:error, %{field: :postal_code, reason: :too_short}}

  @spec normalize(address()) :: address()
  defp normalize(address) do
    %{
      address
      | state_code: String.upcase(address.state_code),
        country_code: String.upcase(address.country_code),
        postal_code: String.trim(address.postal_code)
    }
  end
end
```
