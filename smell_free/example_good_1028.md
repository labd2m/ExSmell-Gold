```elixir
defmodule Shipping.CarrierIntegration do
  @moduledoc """
  Provides a unified interface over multiple carrier HTTP APIs. Each
  carrier's specifics are encapsulated in a dedicated adapter module
  implementing the `Shipping.CarrierAdapter` behaviour. The integration
  layer handles retry logic and translates adapter errors into a
  common error taxonomy so callers remain decoupled from carrier details.
  """

  require Logger

  @type tracking_number :: String.t()
  @type label_params :: %{
          recipient: map(),
          weight_grams: pos_integer(),
          service_class: atom(),
          reference: String.t()
        }

  @type label_result :: %{tracking_number: tracking_number(), label_base64: String.t(), carrier: atom()}
  @type tracking_event :: %{status: String.t(), location: String.t() | nil, timestamp: DateTime.t()}

  @max_retries 3

  @doc """
  Creates a shipping label via `carrier`. Retries up to #{@max_retries} times
  on transient failures. Returns the label and tracking number on success.
  """
  @spec create_label(atom(), label_params()) ::
          {:ok, label_result()} | {:error, :carrier_error | :invalid_params | :timeout}
  def create_label(carrier, params) when is_atom(carrier) and is_map(params) do
    adapter = adapter_for(carrier)
    attempt_with_retry(fn -> adapter.create_label(params) end, @max_retries, carrier, :create_label)
  end

  @doc "Fetches the latest tracking events for `tracking_number` via `carrier`."
  @spec track(atom(), tracking_number()) ::
          {:ok, [tracking_event()]} | {:error, :not_found | :carrier_error}
  def track(carrier, tracking_number) when is_atom(carrier) and is_binary(tracking_number) do
    adapter = adapter_for(carrier)
    attempt_with_retry(fn -> adapter.track(tracking_number) end, @max_retries, carrier, :track)
  end

  @doc "Cancels a shipment label, void-marking it at the carrier."
  @spec void_label(atom(), tracking_number()) :: :ok | {:error, :void_failed | :not_found}
  def void_label(carrier, tracking_number) when is_atom(carrier) and is_binary(tracking_number) do
    adapter = adapter_for(carrier)
    case adapter.void_label(tracking_number) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :void_failed}
    end
  end

  defp attempt_with_retry(fun, retries_left, carrier, operation) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, reason} when retries_left > 0 and reason in [:timeout, :carrier_unavailable] ->
        Logger.warning("[CarrierIntegration] #{carrier} #{operation} failed (#{reason}), retrying")
        Process.sleep(500)
        attempt_with_retry(fun, retries_left - 1, carrier, operation)

      {:error, reason} ->
        Logger.error("[CarrierIntegration] #{carrier} #{operation} failed: #{inspect(reason)}")
        {:error, classify_error(reason)}
    end
  end

  defp classify_error(:invalid_params), do: :invalid_params
  defp classify_error(:not_found), do: :not_found
  defp classify_error(:timeout), do: :timeout
  defp classify_error(_), do: :carrier_error

  defp adapter_for(carrier) do
    adapters = Application.get_env(:my_app, :carrier_adapters, %{})
    Map.fetch!(adapters, carrier)
  end
end

defmodule Shipping.CarrierAdapter do
  @moduledoc "Behaviour for carrier-specific HTTP adapter modules."

  @callback create_label(params :: map()) ::
              {:ok, Shipping.CarrierIntegration.label_result()} | {:error, term()}

  @callback track(tracking_number :: String.t()) ::
              {:ok, [Shipping.CarrierIntegration.tracking_event()]} | {:error, term()}

  @callback void_label(tracking_number :: String.t()) :: :ok | {:error, term()}
end
```
