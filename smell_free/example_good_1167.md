**File:** `example_good_1167.md`

```elixir
defmodule Onboarding.ProfileForm do
  @moduledoc "Validated struct representing a completed user onboarding profile form."

  @enforce_keys [:full_name, :email, :date_of_birth, :country_code, :agreed_to_terms]
  defstruct [:full_name, :email, :date_of_birth, :country_code, :agreed_to_terms, :referral_code]

  @type t :: %__MODULE__{
          full_name: String.t(),
          email: String.t(),
          date_of_birth: Date.t(),
          country_code: String.t(),
          agreed_to_terms: true,
          referral_code: String.t() | nil
        }
end

defmodule Onboarding.ProfileForm.Validator do
  @moduledoc """
  Validates raw user-submitted parameters for the onboarding profile form.
  Returns a typed struct on success or a detailed error map on failure.
  """

  alias Onboarding.ProfileForm

  @type raw_params :: %{String.t() => String.t()}
  @type validation_result :: {:ok, ProfileForm.t()} | {:error, %{atom() => [String.t()]}}

  @minimum_age 18
  @valid_country_codes ~w(US CA GB AU DE FR BR JP IN ZA)

  @spec validate(raw_params()) :: validation_result()
  def validate(params) when is_map(params) do
    with {:ok, full_name} <- validate_full_name(params["full_name"]),
         {:ok, email} <- validate_email(params["email"]),
         {:ok, dob} <- validate_date_of_birth(params["date_of_birth"]),
         {:ok, country_code} <- validate_country_code(params["country_code"]),
         :ok <- validate_terms(params["agreed_to_terms"]) do
      {:ok, %ProfileForm{
        full_name: full_name,
        email: email,
        date_of_birth: dob,
        country_code: country_code,
        agreed_to_terms: true,
        referral_code: normalize_referral(params["referral_code"])
      }}
    end
  end

  defp validate_full_name(nil), do: field_error(:full_name, "is required")
  defp validate_full_name(""), do: field_error(:full_name, "cannot be blank")
  defp validate_full_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if String.length(trimmed) >= 2 and String.length(trimmed) <= 120 do
      {:ok, trimmed}
    else
      field_error(:full_name, "must be between 2 and 120 characters")
    end
  end

  defp validate_full_name(_), do: field_error(:full_name, "must be a string")

  defp validate_email(nil), do: field_error(:email, "is required")
  defp validate_email(email) when is_binary(email) do
    trimmed = String.trim(String.downcase(email))
    if String.match?(trimmed, ~r/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/) do
      {:ok, trimmed}
    else
      field_error(:email, "is not a valid email address")
    end
  end

  defp validate_email(_), do: field_error(:email, "must be a string")

  defp validate_date_of_birth(nil), do: field_error(:date_of_birth, "is required")
  defp validate_date_of_birth(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> check_minimum_age(date)
      {:error, _} -> field_error(:date_of_birth, "must be in YYYY-MM-DD format")
    end
  end

  defp validate_date_of_birth(_), do: field_error(:date_of_birth, "must be a string")

  defp check_minimum_age(date) do
    age = Date.diff(Date.utc_today(), date) |> div(365)
    if age >= @minimum_age do
      {:ok, date}
    else
      field_error(:date_of_birth, "must be at least #{@minimum_age} years old")
    end
  end

  defp validate_country_code(nil), do: field_error(:country_code, "is required")
  defp validate_country_code(code) when is_binary(code) do
    upcased = String.upcase(String.trim(code))
    if upcased in @valid_country_codes do
      {:ok, upcased}
    else
      field_error(:country_code, "is not a supported country code")
    end
  end

  defp validate_country_code(_), do: field_error(:country_code, "must be a string")

  defp validate_terms("true"), do: :ok
  defp validate_terms(true), do: :ok
  defp validate_terms(_), do: field_error(:agreed_to_terms, "must be accepted to continue")

  defp normalize_referral(nil), do: nil
  defp normalize_referral(""), do: nil
  defp normalize_referral(code) when is_binary(code), do: String.upcase(String.trim(code))

  defp field_error(field, message), do: {:error, %{field => [message]}}
end
```
