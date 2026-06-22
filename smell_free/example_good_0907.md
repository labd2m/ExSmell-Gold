```elixir
defmodule Commerce.TaxExemptionContext do
  @moduledoc """
  Manages tax exemption certificates for business customers. A certificate
  covers specific tax categories and jurisdictions for a defined period.
  The context validates certificate applicability before allowing it to
  be applied to an order, preventing expired or out-of-scope certificates
  from incorrectly zeroing tax lines.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Commerce.{TaxCertificate, Order}

  @type customer_id :: String.t()
  @type certificate_id :: Ecto.UUID.t()
  @type jurisdiction :: String.t()
  @type tax_category :: String.t()

  @doc "Registers a new exemption certificate for a business customer."
  @spec register(customer_id(), String.t(), [jurisdiction()], [tax_category()], Date.t(), Date.t()) ::
          {:ok, TaxCertificate.t()} | {:error, :invalid_dates | Ecto.Changeset.t()}
  def register(customer_id, certificate_number, jurisdictions, categories, valid_from, valid_until)
      when is_binary(customer_id) and is_binary(certificate_number) do
    if Date.compare(valid_from, valid_until) == :gt do
      {:error, :invalid_dates}
    else
      attrs = %{
        customer_id: customer_id,
        certificate_number: certificate_number,
        jurisdictions: jurisdictions,
        tax_categories: categories,
        valid_from: valid_from,
        valid_until: valid_until,
        active: true
      }
      %TaxCertificate{} |> TaxCertificate.changeset(attrs) |> Repo.insert()
    end
  end

  @doc """
  Returns true when the customer has an active certificate covering the
  given `jurisdiction` and `tax_category` on `reference_date`.
  """
  @spec exempt?(customer_id(), jurisdiction(), tax_category(), Date.t()) :: boolean()
  def exempt?(customer_id, jurisdiction, tax_category, reference_date \\\\ Date.utc_today()) do
    Repo.exists?(
      from(c in TaxCertificate,
        where: c.customer_id == ^customer_id
               and c.active == true
               and ^jurisdiction in c.jurisdictions
               and ^tax_category in c.tax_categories
               and c.valid_from <= ^reference_date
               and c.valid_until >= ^reference_date
      )
    )
  end

  @doc "Returns all active certificates for `customer_id`."
  @spec list_active(customer_id()) :: [TaxCertificate.t()]
  def list_active(customer_id) when is_binary(customer_id) do
    today = Date.utc_today()

    from(c in TaxCertificate,
      where: c.customer_id == ^customer_id and c.active == true and c.valid_until >= ^today,
      order_by: [asc: c.valid_from]
    )
    |> Repo.all()
  end

  @doc "Revokes a certificate, preventing it from applying to future orders."
  @spec revoke(certificate_id()) :: :ok | {:error, :not_found}
  def revoke(certificate_id) when is_binary(certificate_id) do
    case Repo.get(TaxCertificate, certificate_id) do
      nil -> {:error, :not_found}
      cert ->
        cert |> TaxCertificate.changeset(%{active: false}) |> Repo.update!()
        :ok
    end
  end

  @doc """
  Returns the set of tax categories that are exempt for `customer_id`
  in `jurisdiction` on the given date, based on active certificates.
  """
  @spec exempt_categories(customer_id(), jurisdiction(), Date.t()) :: MapSet.t()
  def exempt_categories(customer_id, jurisdiction, date \\\\ Date.utc_today()) do
    from(c in TaxCertificate,
      where: c.customer_id == ^customer_id
             and c.active == true
             and ^jurisdiction in c.jurisdictions
             and c.valid_from <= ^date
             and c.valid_until >= ^date,
      select: c.tax_categories
    )
    |> Repo.all()
    |> List.flatten()
    |> MapSet.new()
  end
end
```
