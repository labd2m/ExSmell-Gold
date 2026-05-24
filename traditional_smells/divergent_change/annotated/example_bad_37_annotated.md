# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `VendorPortal` module (entire module)
- **Affected functions:** `onboard_vendor/1`, `update_vendor_contract/2`, `create_purchase_order/3`, `receive_purchase_order/2`, `process_vendor_payment/2`, `put_payment_on_hold/2`
- **Explanation:** `VendorPortal` merges vendor onboarding/contract management, purchase order creation and receiving, and vendor payment processing. Each represents a separate domain: vendor onboarding rules may change with compliance, PO workflows may change with procurement policies, and payment processing may change with finance system integrations.

---

```elixir
defmodule MyApp.VendorPortal do
  @moduledoc """
  Manages vendor relationships including onboarding, contract maintenance,
  purchase order management, and outbound vendor payments.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Vendor, VendorContract, PurchaseOrder, PurchaseOrderLine, VendorPayment}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because vendor onboarding, contract management,
  # purchase order workflows, and payment processing are four independent domains.
  # KYC compliance changes affect onboarding, legal policy changes affect
  # contracts, procurement changes affect POs, and ERP integration changes
  # affect payments — each driving unrelated modifications to this single module.

  ## ── Vendor Onboarding & Contracts ───────────────────────────────────────────

  @doc """
  Registers a new vendor after validating required legal and banking details.
  """
  def onboard_vendor(attrs) do
    required = [:legal_name, :tax_id, :bank_account_number, :bank_routing_number, :contact_email]

    missing = Enum.filter(required, &(not Map.has_key?(attrs, &1)))

    if missing != [] do
      {:error, {:missing_fields, missing}}
    else
      %Vendor{}
      |> Vendor.changeset(Map.merge(attrs, %{status: :pending_review, onboarded_at: DateTime.utc_now()}))
      |> Repo.insert()
    end
  end

  @doc """
  Records a new or updated contract for a vendor.
  """
  def update_vendor_contract(%Vendor{} = vendor, contract_attrs) do
    existing = Repo.get_by(VendorContract, vendor_id: vendor.id, active: true)

    if existing, do: Repo.update!(VendorContract.changeset(existing, %{active: false}))

    %VendorContract{}
    |> VendorContract.changeset(
      Map.merge(contract_attrs, %{
        vendor_id: vendor.id,
        active: true,
        signed_at: DateTime.utc_now()
      })
    )
    |> Repo.insert()
  end

  ## ── Purchase Orders ──────────────────────────────────────────────────────────

  @doc """
  Creates a new purchase order for a vendor with the given line items.
  """
  def create_purchase_order(%Vendor{} = vendor, buyer_id, line_items) do
    subtotal = Enum.sum(Enum.map(line_items, & &1.unit_price_cents * &1.quantity))

    Repo.transaction(fn ->
      po =
        %PurchaseOrder{}
        |> PurchaseOrder.changeset(%{
          vendor_id: vendor.id,
          buyer_id: buyer_id,
          subtotal_cents: subtotal,
          status: :pending,
          created_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      Enum.each(line_items, fn item ->
        %PurchaseOrderLine{}
        |> PurchaseOrderLine.changeset(Map.put(item, :purchase_order_id, po.id))
        |> Repo.insert!()
      end)

      po
    end)
  end

  @doc """
  Marks a purchase order as received and records receipt timestamp.
  """
  def receive_purchase_order(%PurchaseOrder{status: :pending} = po, received_by) do
    po
    |> PurchaseOrder.changeset(%{
      status: :received,
      received_by: received_by,
      received_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def receive_purchase_order(%PurchaseOrder{}, _), do: {:error, :not_in_pending_state}

  ## ── Vendor Payments ──────────────────────────────────────────────────────────

  @doc """
  Issues a payment to the vendor for a received purchase order.
  """
  def process_vendor_payment(%PurchaseOrder{status: :received} = po, approved_by) do
    vendor = Repo.get!(Vendor, po.vendor_id)

    with {:ok, transfer} <-
           MyApp.Banking.initiate_ach_transfer(%{
             routing: vendor.bank_routing_number,
             account: vendor.bank_account_number,
             amount_cents: po.subtotal_cents,
             memo: "PO-#{po.id}"
           }) do
      %VendorPayment{}
      |> VendorPayment.changeset(%{
        purchase_order_id: po.id,
        vendor_id: vendor.id,
        amount_cents: po.subtotal_cents,
        ach_transfer_id: transfer.id,
        status: :processing,
        approved_by: approved_by,
        initiated_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  def process_vendor_payment(%PurchaseOrder{}, _), do: {:error, :order_not_yet_received}

  @doc """
  Places a vendor payment on hold pending manual review.
  """
  def put_payment_on_hold(%VendorPayment{status: :processing} = payment, reason) do
    payment
    |> VendorPayment.changeset(%{status: :on_hold, hold_reason: reason, held_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def put_payment_on_hold(%VendorPayment{}, _), do: {:error, :cannot_hold_non_processing_payment}

  # VALIDATION: SMELL END
end
```
