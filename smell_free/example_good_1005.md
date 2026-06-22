```elixir
defmodule MyApp.Logistics.ManifestBuilder do
  @moduledoc """
  Builds carrier shipping manifests by grouping shipments by carrier
  and generating a single manifest document per carrier per dispatch
  window. Manifests are submitted to the carrier's API in bulk, which
  is more efficient than individual label creation and satisfies end-of-
  day cut-off requirements.
  """

  alias MyApp.Repo
  alias MyApp.Shipping.{Shipment, Manifest}
  alias MyApp.Shipping.Adapters

  import Ecto.Query, warn: false

  @type carrier :: String.t()
  @type manifest_result :: %{
          carrier: carrier(),
          manifest_id: String.t(),
          shipment_count: non_neg_integer(),
          submitted_at: DateTime.t()
        }

  @doc """
  Builds and submits manifests for all unmanifested shipments in the
  current dispatch window. Returns one result per carrier with at least
  one eligible shipment.
  """
  @spec build_and_submit() :: [manifest_result()]
  def build_and_submit do
    unmanifested_shipments()
    |> Enum.group_by(& &1.carrier)
    |> Enum.flat_map(fn {carrier, shipments} ->
      case submit_manifest(carrier, shipments) do
        {:ok, result} -> [result]
        {:error, reason} ->
          require Logger
          Logger.error("manifest_submission_failed", carrier: carrier, reason: inspect(reason))
          []
      end
    end)
  end

  @doc "Returns shipments that have a label but have not yet been added to a manifest."
  @spec unmanifested_shipments() :: [Shipment.t()]
  def unmanifested_shipments do
    Shipment
    |> where([s], not is_nil(s.tracking_number) and is_nil(s.manifest_id))
    |> where([s], s.status == :label_printed)
    |> order_by([s], asc: s.carrier, asc: s.inserted_at)
    |> Repo.all()
  end

  @spec submit_manifest(carrier(), [Shipment.t()]) ::
          {:ok, manifest_result()} | {:error, term()}
  defp submit_manifest(carrier, shipments) do
    adapter = Adapters.for_carrier(carrier)
    tracking_numbers = Enum.map(shipments, & &1.tracking_number)

    with {:ok, manifest_id} <- adapter.close_manifest(tracking_numbers),
         {:ok, _record} <- persist_manifest(carrier, manifest_id, shipments) do
      mark_manifested(shipments, manifest_id)

      {:ok, %{
        carrier: carrier,
        manifest_id: manifest_id,
        shipment_count: length(shipments),
        submitted_at: DateTime.utc_now()
      }}
    end
  end

  @spec persist_manifest(carrier(), String.t(), [Shipment.t()]) ::
          {:ok, Manifest.t()} | {:error, Ecto.Changeset.t()}
  defp persist_manifest(carrier, manifest_id, shipments) do
    %Manifest{}
    |> Manifest.changeset(%{
      carrier: carrier,
      provider_manifest_id: manifest_id,
      shipment_count: length(shipments),
      submitted_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec mark_manifested([Shipment.t()], String.t()) :: :ok
  defp mark_manifested(shipments, manifest_id) do
    ids = Enum.map(shipments, & &1.id)

    Shipment
    |> where([s], s.id in ^ids)
    |> Repo.update_all(set: [manifest_id: manifest_id, status: :manifested])

    :ok
  end
end
```
