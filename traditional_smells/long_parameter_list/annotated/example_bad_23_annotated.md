# Annotated Example 23 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Banking.Accounts.open_account/10` |
| **Affected function(s)** | `open_account/10` |
| **Explanation** | The function takes 10 positional parameters covering personal identity (full_name, national_id, birth_date, email), address (street, city, country), and account configuration (account_type, currency, initial_deposit). These map to at least `%PersonalDetails{}` and `%AccountConfig{}` groupings rather than a flat, positional list that is easy to misuse. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `open_account/10` takes ten individual
# positional parameters. The personal identity data (full_name, national_id,
# birth_date, email), residential address (street, city, country), and
# account configuration (account_type, currency, initial_deposit) form
# three distinct conceptual groups. Passing all ten as positional scalars
# creates a confusing interface where several string-typed arguments sit
# adjacent and can easily be transposed.
defmodule Banking.Accounts do
  @moduledoc """
  Manages bank account opening, KYC verification, and initial deposit processing.
  """

  require Logger

  alias Banking.Repo
  alias Banking.Schemas.BankAccount
  alias Banking.Schemas.KYCRecord
  alias Banking.KYCVerifier
  alias Banking.LedgerService
  alias Banking.Mailer

  @valid_account_types ~w(checking savings investment)
  @supported_currencies ~w(USD EUR GBP BRL CHF)
  @minimum_deposits %{"checking" => 0, "savings" => 100, "investment" => 1000}

  def open_account(
        full_name,
        national_id,
        birth_date,
        email,
        street,
        city,
        country,
        account_type,
        currency,
        initial_deposit
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_account_type(account_type),
         :ok <- validate_currency(currency),
         :ok <- validate_deposit(account_type, initial_deposit),
         :ok <- validate_email(email),
         :ok <- validate_birth_date(birth_date) do
      kyc_result = KYCVerifier.verify(national_id, full_name, birth_date)

      case kyc_result do
        {:ok, kyc_ref} ->
          account_number = generate_account_number()

          account_attrs = %{
            full_name: full_name,
            email: String.downcase(String.trim(email)),
            street: street,
            city: city,
            country: country,
            account_type: account_type,
            currency: currency,
            account_number: account_number,
            balance: initial_deposit,
            status: :active,
            inserted_at: DateTime.utc_now()
          }

          Repo.transaction(fn ->
            {:ok, account} = Repo.insert(BankAccount.changeset(%BankAccount{}, account_attrs))

            Repo.insert!(KYCRecord.changeset(%KYCRecord{}, %{
              account_id: account.id,
              national_id_hash: :crypto.hash(:sha256, national_id) |> Base.encode16(),
              kyc_ref: kyc_ref,
              verified_at: DateTime.utc_now()
            }))

            if initial_deposit > 0 do
              LedgerService.record_deposit(account.id, initial_deposit, currency)
            end

            Mailer.send_account_confirmation(email, full_name, account)
            Logger.info("Account #{account_number} opened for #{email}")
            account
          end)

        {:error, :kyc_failed} ->
          Logger.warn("KYC failed for national_id #{national_id}")
          {:error, :kyc_verification_failed}
      end
    end
  end

  defp validate_account_type(t) when t in @valid_account_types, do: :ok
  defp validate_account_type(t), do: {:error, {:unknown_account_type, t}}

  defp validate_currency(c) when c in @supported_currencies, do: :ok
  defp validate_currency(c), do: {:error, {:unsupported_currency, c}}

  defp validate_deposit(account_type, deposit) do
    minimum = Map.get(@minimum_deposits, account_type, 0)
    if is_number(deposit) and deposit >= minimum do
      :ok
    else
      {:error, {:deposit_below_minimum, minimum}}
    end
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_birth_date(date) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        age = Date.diff(Date.utc_today(), d) |> div(365)
        if age >= 18, do: :ok, else: {:error, :underage}

      _ ->
        {:error, :invalid_birth_date}
    end
  end

  defp generate_account_number do
    :crypto.strong_rand_bytes(5)
    |> Base.encode16()
    |> String.slice(0, 10)
  end
end
```
