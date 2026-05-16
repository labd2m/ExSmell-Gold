# Annotated Bad Example 12

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `onboard_supplier/2`, inside the `with` block's `else` clause
- **Affected function(s):** `onboard_supplier/2`
- **Short explanation:** Supplier onboarding runs five steps—validating business data, verifying tax ID with an external authority, checking blacklists, persisting the supplier record, and setting up a payment account. All distinct error shapes from these steps are merged into a single `else` block, making failure attribution ambiguous.

```elixir
defmodule Procurement.SupplierOnboarding do
  alias Procurement.{Repo, Supplier, TaxAuthorityClient, BlacklistRegistry, PaymentAccountService}

  require Logger

  @required_fields ~w[legal_name tax_id country bank_account_iban contact_email]

  def onboard_supplier(params, onboarded_by) do
    with {:ok, validated} <- validate_supplier_params(params),
         {:ok, tax_record} <- TaxAuthorityClient.verify(validated.tax_id, validated.country),
         :ok <- BlacklistRegistry.check(validated.tax_id, validated.legal_name),
         {:ok, supplier} <- persist_supplier(validated, tax_record, onboarded_by),
         {:ok, payment_account} <- PaymentAccountService.create(supplier) do
      Logger.info(
        "Supplier #{supplier.id} (#{supplier.legal_name}) onboarded by #{onboarded_by}"
      )

      {:ok, %{supplier: supplier, payment_account: payment_account}}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because errors from five independent steps are all
      # handled in this single `else` block. Validation errors (`{:missing_fields, _}`,
      # `{:invalid_iban, _}`) come from step 1; tax verification errors (`:tax_id_not_found`,
      # `:tax_authority_unavailable`) from step 2; blacklist errors (`:blacklisted`) from
      # step 3; persistence errors (`{:db_error, _}`) from step 4; and payment account
      # errors (`:payment_account_creation_failed`) from step 5.
      {:error, {:missing_fields, fields}} ->
        Logger.warning("Supplier onboarding missing fields: #{inspect(fields)}")
        {:error, {:validation_error, :missing_fields, fields}}

      {:error, {:invalid_iban, iban}} ->
        Logger.warning("Invalid IBAN during supplier onboarding: #{iban}")
        {:error, {:validation_error, :invalid_iban}}

      {:error, :tax_id_not_found} ->
        Logger.warning("Tax ID #{params["tax_id"]} not found with tax authority")
        {:error, :tax_verification_failed}

      {:error, :tax_authority_unavailable} ->
        Logger.error("Tax authority service unavailable during onboarding")
        {:error, :external_service_unavailable}

      {:error, :blacklisted} ->
        Logger.warning("Supplier #{params["legal_name"]} is on the blacklist")
        {:error, :supplier_blacklisted}

      {:error, {:db_error, changeset}} ->
        Logger.error("Supplier persistence failed: #{inspect(changeset.errors)}")
        {:error, :persistence_failed}

      {:error, :payment_account_creation_failed} ->
        Logger.error("Payment account could not be created for supplier")
        {:error, :payment_setup_failed}

      {:error, reason} ->
        Logger.error("Unexpected supplier onboarding error: #{inspect(reason)}")
        {:error, :internal_error}
      # VALIDATION: SMELL END
    end
  end

  defp validate_supplier_params(params) do
    missing = Enum.reject(@required_fields, &Map.has_key?(params, &1))

    if missing != [] do
      {:error, {:missing_fields, missing}}
    else
      iban = params["bank_account_iban"]

      if valid_iban?(iban) do
        {:ok, atomize_keys(params)}
      else
        {:error, {:invalid_iban, iban}}
      end
    end
  end

  defp persist_supplier(validated, tax_record, onboarded_by) do
    %Supplier{}
    |> Supplier.changeset(%{
      legal_name: validated.legal_name,
      tax_id: validated.tax_id,
      country: validated.country,
      bank_account_iban: validated.bank_account_iban,
      contact_email: validated.contact_email,
      tax_status: tax_record.status,
      onboarded_by: onboarded_by,
      status: :pending_review
    })
    |> Repo.insert()
    |> case do
      {:ok, supplier} -> {:ok, supplier}
      {:error, cs} -> {:error, {:db_error, cs}}
    end
  end

  defp valid_iban?(iban) when is_binary(iban), do: String.match?(iban, ~r/^[A-Z]{2}\d{2}[\w]{1,30}$/)
  defp valid_iban?(_), do: false

  defp atomize_keys(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
end
```
