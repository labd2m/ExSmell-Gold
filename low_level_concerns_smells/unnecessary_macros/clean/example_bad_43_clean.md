```elixir
defmodule UserManagement.AddressHelper do
  @moduledoc """
  Utilities for validating, normalising, and merging user address data
  collected from registration forms, third-party KYC providers, and
  manual CSR updates.
  """

  @required_fields ~w(street city state country zip_code)a
  @valid_countries ~w(US BR GB DE FR)


  def validate(address) when is_map(address) do
    missing = Enum.reject(@required_fields, &Map.get(address, &1))

    cond do
      missing != [] ->
        {:error, "Missing fields: #{Enum.join(missing, ", ")}"}

      address.country not in @valid_countries ->
        {:error, "Unsupported country: #{address.country}"}

      not valid_zip?(address.zip_code, address.country) ->
        {:error, "Invalid zip code for #{address.country}"}

      true ->
        {:ok, normalise(address)}
    end
  end

  defp normalise(address) do
    %{
      address
      | street: String.trim(address.street),
        city: String.trim(address.city),
        state: String.upcase(String.trim(address.state)),
        zip_code: String.replace(address.zip_code, ~r/\s/, "")
    }
  end

  def valid_zip?("", _), do: false
  def valid_zip?(zip, "US"), do: Regex.match?(~r/^\d{5}(-\d{4})?$/, zip)
  def valid_zip?(zip, "BR"), do: Regex.match?(~r/^\d{5}-?\d{3}$/, zip)
  def valid_zip?(zip, "GB"), do: Regex.match?(~r/^[A-Z]{1,2}\d[A-Z\d]? \d[A-Z]{2}$/i, zip)
  def valid_zip?(_, _), do: true

  def apply_kyc_update(stored_address, kyc_address) do
    require UserManagement.AddressHelper
    merged = UserManagement.AddressHelper.merge_address(stored_address, kyc_address)

    case validate(merged) do
      {:ok, validated} -> {:ok, validated}
      {:error, _} = err -> err
    end
  end

  def apply_csr_patch(stored_address, patch_map) do
    require UserManagement.AddressHelper
    merged = UserManagement.AddressHelper.merge_address(stored_address, patch_map)
    validate(merged)
  end

  def to_display_string(address) do
    "#{address.street}, #{address.city}, #{address.state} #{address.zip_code}, #{address.country}"
  end

  def to_shipping_label(address, recipient_name) do
    """
    #{recipient_name}
    #{address.street}
    #{address.city}, #{address.state} #{address.zip_code}
    #{address.country}
    """
  end

  def same_address?(a, b) do
    normalise_key = fn addr ->
      Map.take(addr, @required_fields)
      |> Map.new(fn {k, v} -> {k, String.downcase(to_string(v))} end)
    end

    normalise_key.(a) == normalise_key.(b)
  end
end
```
