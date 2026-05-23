```elixir
defmodule UserManagement.AddressService do
  @moduledoc """
  Validates, formats, and persists shipping and billing addresses
  for user accounts. Integrates with the geocoding pipeline for
  delivery zone assignment.
  """

  require Logger

  @supported_countries ~w(US CA GB AU BR DE FR)
  @us_state_codes ~w(AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME
                     MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA
                     RI SC SD TN TX UT VT VA WA WV WI WY DC)

  @spec validate_shipping_address(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, list(String.t())}
  def validate_shipping_address(street, city, state, postal_code, country) do
    errors =
      []
      |> validate_street(street)
      |> validate_city(city)
      |> validate_country(country)
      |> validate_state_for_country(state, country)
      |> validate_postal_code_for_country(postal_code, country)

    if errors == [] do
      {:ok,
       %{
         street: String.trim(street),
         city: String.trim(city),
         state: String.upcase(String.trim(state)),
         postal_code: String.trim(postal_code),
         country: String.upcase(String.trim(country))
       }}
    else
      {:error, errors}
    end
  end

  @spec format_address_label(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          String.t()
  def format_address_label(street, city, state, postal_code, country) do
    country_upper = String.upcase(country)

    case country_upper do
      "US" ->
        "#{street}\n#{city}, #{String.upcase(state)} #{postal_code}\nUnited States"

      "CA" ->
        "#{street}\n#{city} #{String.upcase(state)}  #{postal_code}\nCanada"

      "GB" ->
        "#{street}\n#{city}\n#{String.upcase(postal_code)}\nUnited Kingdom"

      "BR" ->
        "#{street}\n#{city} - #{String.upcase(state)}\n#{postal_code}\nBrazil"

      _ ->
        "#{street}\n#{city}, #{state} #{postal_code}\n#{country_upper}"
    end
  end

  @spec geocode_address(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def geocode_address(street, city, state, postal_code, country) do
    query = "#{street}, #{city}, #{state} #{postal_code}, #{country}"
    Logger.debug("Geocoding address query: #{query}")

    # Simulated geocoding response
    {:ok, %{latitude: 37.7749, longitude: -122.4194, formatted_query: query}}
  end

  @spec update_user_address(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, String.t()}
  def update_user_address(user_id, street, city, state, postal_code, country) do
    with {:ok, validated} <- validate_shipping_address(street, city, state, postal_code, country),
         {:ok, _geo} <- geocode_address(street, city, state, postal_code, country) do
      Logger.info("Address updated for user #{user_id}: #{format_address_label(street, city, state, postal_code, country)}")

      updated_user = %{
        id: user_id,
        address: validated,
        address_updated_at: DateTime.utc_now()
      }

      {:ok, updated_user}
    else
      {:error, errors} when is_list(errors) ->
        {:error, "Validation failed: #{Enum.join(errors, "; ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_street(errors, street) do
    if String.trim(street) == "" do
      ["Street cannot be blank" | errors]
    else
      errors
    end
  end

  defp validate_city(errors, city) do
    if String.trim(city) == "" do
      ["City cannot be blank" | errors]
    else
      errors
    end
  end

  defp validate_country(errors, country) do
    if String.upcase(String.trim(country)) not in @supported_countries do
      ["Unsupported country code: #{country}" | errors]
    else
      errors
    end
  end

  defp validate_state_for_country(errors, state, "US") do
    if String.upcase(String.trim(state)) not in @us_state_codes do
      ["Invalid US state code: #{state}" | errors]
    else
      errors
    end
  end

  defp validate_state_for_country(errors, state, _country) do
    if String.trim(state) == "" do
      ["State/province cannot be blank" | errors]
    else
      errors
    end
  end

  defp validate_postal_code_for_country(errors, postal_code, "US") do
    if String.match?(String.trim(postal_code), ~r/^\d{5}(-\d{4})?$/) do
      errors
    else
      ["Invalid US ZIP code: #{postal_code}" | errors]
    end
  end

  defp validate_postal_code_for_country(errors, postal_code, "CA") do
    if String.match?(String.trim(postal_code), ~r/^[A-Za-z]\d[A-Za-z][ -]?\d[A-Za-z]\d$/) do
      errors
    else
      ["Invalid Canadian postal code: #{postal_code}" | errors]
    end
  end

  defp validate_postal_code_for_country(errors, postal_code, _country) do
    if String.trim(postal_code) == "" do
      ["Postal code cannot be blank" | errors]
    else
      errors
    end
  end
end
```
