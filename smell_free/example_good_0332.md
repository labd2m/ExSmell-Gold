```elixir
defmodule Address.PostalAddress do
  @moduledoc """
  A structured postal address value object.
  """

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state_province: String.t() | nil,
          postal_code: String.t(),
          country_code: String.t()
        }

  defstruct [:line1, :line2, :city, :state_province, :postal_code, :country_code]
end

defmodule Address.CountryRules do
  @moduledoc false

  @rules %{
    "US" => %{
      postal_code_format: ~r/\A\d{5}(-\d{4})?\z/,
      requires_state: true,
      state_values: ~w(AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY
                       LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND
                       OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC)
    },
    "GB" => %{
      postal_code_format: ~r/\A[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}\z/i,
      requires_state: false,
      state_values: []
    },
    "CA" => %{
      postal_code_format: ~r/\A[A-Z]\d[A-Z] ?\d[A-Z]\d\z/i,
      requires_state: true,
      state_values: ~w(AB BC MB NB NL NS NT NU ON PE QC SK YT)
    },
    "DE" => %{
      postal_code_format: ~r/\A\d{5}\z/,
      requires_state: false,
      state_values: []
    },
    "BR" => %{
      postal_code_format: ~r/\A\d{5}-?\d{3}\z/,
      requires_state: true,
      state_values: ~w(AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE
                       PI RJ RN RS RO RR SC SP SE TO)
    }
  }

  @spec get(String.t()) :: {:ok, map()} | {:error, :unsupported_country}
  def get(country_code) when is_binary(country_code) do
    case Map.fetch(@rules, String.upcase(country_code)) do
      {:ok, rules} -> {:ok, rules}
      :error -> {:error, :unsupported_country}
    end
  end

  @spec supported_countries() :: [String.t()]
  def supported_countries, do: Map.keys(@rules)
end

defmodule Address.Validator do
  @moduledoc """
  Validates a `PostalAddress` struct against country-specific rules.

  All violations are gathered before returning so callers receive a
  complete description of what must be corrected. An unsupported country
  code produces a single error rather than attempting partial validation
  against unknown rules.
  """

  alias Address.{CountryRules, PostalAddress}

  @type validation_error :: {atom(), String.t()}

  @spec validate(PostalAddress.t()) ::
          :ok | {:error, [validation_error()]}
  def validate(%PostalAddress{} = address) do
    case CountryRules.get(address.country_code) do
      {:error, :unsupported_country} ->
        {:error, [{:country_code, "#{address.country_code} is not a supported country"}]}

      {:ok, rules} ->
        errors =
          []
          |> check_required(:line1, address.line1)
          |> check_required(:city, address.city)
          |> check_postal_code(address.postal_code, rules.postal_code_format)
          |> check_state(address.state_province, rules)

        case errors do
          [] -> :ok
          violations -> {:error, Enum.reverse(violations)}
        end
    end
  end

  defp check_required(errors, _field, value) when is_binary(value) and value != "", do: errors
  defp check_required(errors, field, _), do: [{field, "is required"} | errors]

  defp check_postal_code(errors, code, format) when is_binary(code) do
    if Regex.match?(format, String.trim(code)) do
      errors
    else
      [{:postal_code, "does not match the expected format"} | errors]
    end
  end

  defp check_postal_code(errors, _code, _format) do
    [{:postal_code, "is required"} | errors]
  end

  defp check_state(errors, _state, %{requires_state: false}), do: errors

  defp check_state(errors, state, %{requires_state: true, state_values: []}) when is_binary(state) and state != "" do
    errors
  end

  defp check_state(errors, state, %{requires_state: true, state_values: valid})
       when is_binary(state) and state != "" do
    if state in valid, do: errors, else: [{:state_province, "#{state} is not a valid state or province"} | errors]
  end

  defp check_state(errors, _state, %{requires_state: true}) do
    [{:state_province, "is required for this country"} | errors]
  end
end
```
