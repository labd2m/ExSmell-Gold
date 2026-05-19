# Annotated Example 17 — Large Messages

| Field                  | Value                                                                        |
|------------------------|------------------------------------------------------------------------------|
| **Smell name**         | Large messages                                                               |
| **Expected location**  | `Customs.ClearanceSubmitter.submit/2`                                       |
| **Affected function(s)**| `submit/2`, `handle_cast/2` (GenServer)                                    |
| **Explanation**        | The submitter fetches a full freight manifest — a deeply nested structure containing thousands of cargo items, each with HS classification codes, country-of-origin declarations, valuation breakdowns, and document attachments encoded as Base64 strings — and sends the entire manifest to the `ClearanceProcessor` GenServer in one `GenServer.cast`. Manifest documents are among the largest structures in freight operations; copying one across process boundaries blocks the submitter for a significant period and causes the processor's mailbox to grow when multiple shipments arrive at the same port simultaneously. |

```elixir
defmodule Customs.HsClassification do
  defstruct [
    :hs_code,
    :description,
    :duty_rate_pct,
    :vat_rate_pct,
    :restricted,
    :license_required,
    :end_use_relief
  ]
end

defmodule Customs.CargoItem do
  @enforce_keys [:item_id, :description, :quantity, :gross_weight_kg]
  defstruct [
    :item_id,
    :description,
    :quantity,
    :gross_weight_kg,
    :net_weight_kg,
    :volume_m3,
    :unit_value_usd_cents,
    :total_value_usd_cents,
    :country_of_origin,
    :country_of_manufacture,
    :hs_classification,
    :marks_and_numbers,
    :dangerous_goods_class,
    :certificates
  ]
end

defmodule Customs.ShipperDetails do
  defstruct [:name, :address, :tax_id, :eori_number, :contact_email, :contact_phone]
end

defmodule Customs.FreightManifest do
  @enforce_keys [:manifest_id, :vessel_id, :port_of_loading, :port_of_discharge]
  defstruct [
    :manifest_id,
    :vessel_id,
    :voyage_number,
    :port_of_loading,
    :port_of_discharge,
    :eta,
    :shipper,
    :consignee,
    :cargo_items,
    :total_gross_weight_kg,
    :total_value_usd_cents,
    :document_attachments,
    :seals,
    :remarks
  ]
end

defmodule Customs.ManifestStore do
  @moduledoc "Simulates loading a freight manifest from the logistics platform."

  @spec load(String.t()) :: Customs.FreightManifest.t()
  def load(manifest_id) do
    %Customs.FreightManifest{
      manifest_id: manifest_id,
      vessel_id: "VSL-#{manifest_id}",
      voyage_number: "VOY-2024-#{manifest_id}",
      port_of_loading: "BRSSZ",
      port_of_discharge: "CNSHA",
      eta: DateTime.utc_now() |> DateTime.add(14 * 86_400),
      shipper: %Customs.ShipperDetails{
        name: "Exportadora Brasil Ltda",
        address: "Av. Paulista 1000, São Paulo, SP, 01310-100",
        tax_id: "12.345.678/0001-90",
        eori_number: "BR123456789",
        contact_email: "export@exportadora.com.br",
        contact_phone: "+551132345678"
      },
      consignee: %Customs.ShipperDetails{
        name: "Shanghai Import Co. Ltd",
        address: "100 Pudong Ave, Shanghai, 200120",
        tax_id: "9134XXX",
        eori_number: "CN987654321",
        contact_email: "import@shanghai-co.cn",
        contact_phone: "+862112345678"
      },
      cargo_items: Enum.map(1..8_000, fn i ->
        %Customs.CargoItem{
          item_id: "ITEM-#{manifest_id}-#{i}",
          description: "Manufactured goods type #{rem(i, 50)} — batch #{div(i, 50)}",
          quantity: rem(i, 500) + 1,
          gross_weight_kg: Float.round(10.0 + :rand.uniform() * 990, 3),
          net_weight_kg: Float.round(8.0 + :rand.uniform() * 800, 3),
          volume_m3: Float.round(0.1 + :rand.uniform() * 5, 4),
          unit_value_usd_cents: Enum.random(100..500_000),
          total_value_usd_cents: Enum.random(1_000..50_000_000),
          country_of_origin: Enum.random(["BR", "AR", "CL", "CO"]),
          country_of_manufacture: "BR",
          hs_classification: %Customs.HsClassification{
            hs_code: "#{8400 + rem(i, 100)}.#{rem(i, 90)}.#{rem(i * 3, 99)}",
            description: "HS description for item #{i}",
            duty_rate_pct: Float.round(:rand.uniform() * 20, 2),
            vat_rate_pct: 17.0,
            restricted: rem(i, 200) == 0,
            license_required: rem(i, 100) == 0,
            end_use_relief: false
          },
          marks_and_numbers: "MRK-#{manifest_id}-#{i}",
          dangerous_goods_class: if(rem(i, 500) == 0, do: "3", else: nil),
          certificates: Enum.map(1..3, fn j ->
            %{
              cert_type: Enum.random(["phytosanitary", "origin", "quality"]),
              cert_number: "CERT-#{i}-#{j}",
              issued_by: "Authority #{j}",
              issued_at: Date.utc_today(),
              valid_until: Date.utc_today() |> Date.add(180),
              scan: Base.encode64(:crypto.strong_rand_bytes(64))
            }
          end)
        }
      end),
      total_gross_weight_kg: 4_500_000.0,
      total_value_usd_cents: 980_000_000,
      document_attachments: Enum.map(1..10, fn j ->
        %{name: "doc_#{j}.pdf", content: Base.encode64(:crypto.strong_rand_bytes(128)), mime: "application/pdf"}
      end),
      seals: Enum.map(1..20, fn j -> "SEAL-#{manifest_id}-#{j}" end),
      remarks: "Standard commercial shipment. No special handling required."
    }
  end
end

defmodule Customs.ClearanceProcessor do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{processed: [], errors: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:process_manifest, manifest}, state) do
    restricted_items =
      Enum.filter(manifest.cargo_items, fn item ->
        item.hs_classification.restricted
      end)

    outcome =
      if length(restricted_items) > 0 do
        %{manifest_id: manifest.manifest_id, status: :hold, hold_count: length(restricted_items)}
      else
        %{manifest_id: manifest.manifest_id, status: :cleared}
      end

    {:noreply, %{state | processed: [outcome | state.processed]}}
  end

  @impl true
  def handle_call(:report, _from, state) do
    {:reply, state, state}
  end
end

defmodule Customs.ClearanceSubmitter do
  @moduledoc "Loads freight manifests and submits them for customs clearance processing."

  require Logger

  @spec submit(pid(), String.t()) :: :ok
  def submit(processor_pid, manifest_id) do
    Logger.info("Loading manifest #{manifest_id} for customs submission")

    manifest = Customs.ManifestStore.load(manifest_id)

    Logger.info(
      "Manifest #{manifest_id} loaded — #{length(manifest.cargo_items)} cargo items — submitting to processor"
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `manifest` is a FreightManifest
    # struct containing 8 000 CargoItem structs, each with an HsClassification
    # struct and a list of 3 certificate maps (each embedding a Base64-encoded
    # binary). The manifest also carries 10 document attachment maps with
    # larger Base64 binaries and 20 seal strings. Casting this entire structure
    # to the ClearanceProcessor in one message triggers a deep heap copy of
    # all nested terms. The submitter process is blocked throughout the copy,
    # and when many vessels arrive simultaneously — as happens at peak port
    # hours — every submitter process is blocked at the same time, causing
    # visible latency spikes in the customs clearance pipeline.
    GenServer.cast(processor_pid, {:process_manifest, manifest})
    # VALIDATION: SMELL END

    :ok
  end

  @spec submit_all(pid(), list(String.t())) :: :ok
  def submit_all(processor_pid, manifest_ids) do
    Enum.each(manifest_ids, &submit(processor_pid, &1))
  end
end
```
