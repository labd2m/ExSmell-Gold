```elixir
defmodule MyApp.Catalogue.StockAlertManager do
  @moduledoc """
  Sends restocking alerts to subscribed merchants when a product's
  available inventory falls below a configured threshold. Alert state is
  persisted in the `stock_alerts` table to prevent duplicate notifications
  within a configurable cooldown window.

  Alerts are triggered by calling `evaluate/2` after any stock-level
  change; the function is idempotent and safe to call on every inventory
  update.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Catalogue.{Product, StockAlert}
  alias MyApp.Notifications.Dispatcher

  import Ecto.Query, warn: false

  @default_cooldown_hours 24

  @type sku :: String.t()
  @type available :: non_neg_integer()

  @doc """
  Evaluates whether a low-stock alert should be fired for `sku` given
  its current `available` count. Respects the cooldown window to suppress
  repeated alerts during a sustained low-stock period.
  """
  @spec evaluate(sku(), available()) :: :ok
  def evaluate(sku, available) when is_binary(sku) and is_integer(available) do
    case Repo.get_by(Product, sku: sku) do
      nil ->
        Logger.warning("stock_alert_unknown_sku", sku: sku)
        :ok

      product ->
        maybe_alert(product, available)
    end
  end

  @doc "Returns all unacknowledged stock alerts ordered by severity."
  @spec pending_alerts() :: [StockAlert.t()]
  def pending_alerts do
    StockAlert
    |> where([a], is_nil(a.acknowledged_at))
    |> order_by([a], asc: a.available_at_trigger)
    |> Repo.all()
  end

  @doc "Marks alert `id` as acknowledged, suppressing further escalations."
  @spec acknowledge(String.t()) :: :ok | {:error, :not_found}
  def acknowledge(alert_id) when is_binary(alert_id) do
    case Repo.get(StockAlert, alert_id) do
      nil ->
        {:error, :not_found}

      alert ->
        alert
        |> StockAlert.acknowledge_changeset()
        |> Repo.update()

        :ok
    end
  end

  @spec maybe_alert(Product.t(), available()) :: :ok
  defp maybe_alert(product, available) do
    if below_threshold?(product, available) and not in_cooldown?(product) do
      fire_alert(product, available)
    end

    :ok
  end

  @spec below_threshold?(Product.t(), available()) :: boolean()
  defp below_threshold?(product, available) do
    is_integer(product.low_stock_threshold) and available <= product.low_stock_threshold
  end

  @spec in_cooldown?(Product.t()) :: boolean()
  defp in_cooldown?(product) do
    cooldown_hours = product.alert_cooldown_hours || @default_cooldown_hours
    cutoff = DateTime.add(DateTime.utc_now(), -cooldown_hours, :hour)

    StockAlert
    |> where([a], a.product_id == ^product.id and a.triggered_at > ^cutoff)
    |> Repo.exists?()
  end

  @spec fire_alert(Product.t(), available()) :: :ok
  defp fire_alert(product, available) do
    Logger.info("stock_alert_firing", sku: product.sku, available: available)

    with {:ok, alert} <- record_alert(product, available) do
      Dispatcher.dispatch(%{
        channels: [:email],
        recipient_email: product.merchant_email,
        subject: "Low stock alert: #{product.name}",
        body: "#{product.name} (SKU: #{product.sku}) has #{available} unit(s) remaining.",
        id: alert.id
      })
    end

    :ok
  end

  @spec record_alert(Product.t(), available()) ::
          {:ok, StockAlert.t()} | {:error, Ecto.Changeset.t()}
  defp record_alert(product, available) do
    %StockAlert{}
    |> StockAlert.changeset(%{
      product_id: product.id,
      sku: product.sku,
      available_at_trigger: available,
      threshold: product.low_stock_threshold,
      triggered_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
```
