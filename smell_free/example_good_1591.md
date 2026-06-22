```elixir
defmodule AddressValidator.Address do
  @moduledoc """
  A postal address candidate submitted for validation.
  """

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state_code: String.t(),
          postal_code: String.t(),
          country_code: String.t()
        }

  defstruct [:line1, :line2, :city, :state_code, :postal_code, :country_code]
end

defmodule AddressValidator.Result do
  @moduledoc """
  The outcome of an address validation attempt, including any corrected fields.
  """

  @type t :: %__MODULE__{
          valid: boolean(),
          corrected: AddressValidator.Address.t() | nil,
          issues: [String.t()],
          dpv_confirmed: boolean()
        }

  defstruct [:corrected, valid: false, issues: [], dpv_confirmed: false]
end

defmodule AddressValidator do
  alias AddressValidator.{Address, Result}

  @moduledoc """
  Validates and normalizes postal addresses through a configurable
  provider backend, with local pre-validation to reduce unnecessary API calls.
  """

  @us_state_codes ~w(AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME
    MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX
    UT VT VA WA WV WI WY DC)

  @spec validate(Address.t(), module(), keyword()) ::
          {:ok, Result.t()} | {:error, :provider_unavailable | term()}
  def validate(%Address{} = address, provider, opts \\ [])
      when is_atom(provider) do
    case pre_validate(address) do
      {:error, issues} ->
        {:ok, %Result{valid: false, issues: issues}}

      :ok ->
        provider.validate(normalize_input(address), opts)
    end
  end

  defp pre_validate(%Address{} = addr) do
    issues =
      []
      |> check_required_field("line1", addr.line1)
      |> check_required_field("city", addr.city)
      |> check_required_field("postal_code", addr.postal_code)
      |> check_required_field("country_code", addr.country_code)
      |> check_us_state(addr)
      |> check_us_postal_code(addr)

    case issues do
      [] -> :ok
      _ -> {:error, issues}
    end
  end

  defp check_required_field(issues, _name, value)
       when is_binary(value) and value != "",
       do: issues

  defp check_required_field(issues, name, _), do: issues ++ ["#{name} is required"]

  defp check_us_state(issues, %Address{country_code: "US", state_code: code}) do
    if code in @us_state_codes do
      issues
    else
      issues ++ ["state_code '#{code}' is not a valid US state"]
    end
  end

  defp check_us_state(issues, _), do: issues

  defp check_us_postal_code(issues, %Address{country_code: "US", postal_code: zip}) do
    if String.match?(zip, ~r/^\d{5}(-\d{4})?$/) do
      issues
    else
      issues ++ ["postal_code must be 5 or 9 digits for US addresses"]
    end
  end

  defp check_us_postal_code(issues, _), do: issues

  defp normalize_input(%Address{} = addr) do
    %{addr |
      line1: String.upcase(String.trim(addr.line1)),
      city: String.upcase(String.trim(addr.city)),
      state_code: String.upcase(String.trim(addr.state_code || "")),
      postal_code: String.trim(addr.postal_code),
      country_code: String.upcase(String.trim(addr.country_code))
    }
  end
end
```
