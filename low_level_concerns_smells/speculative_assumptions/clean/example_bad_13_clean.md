```elixir
defmodule Payments.TransactionReferenceParser do
  @moduledoc """
  Parses composite transaction reference strings stored in the payments ledger.

  The platform wraps gateway-native transaction identifiers in a composite
  reference that encodes the originating gateway, deployment environment, and
  the gateway's own identifier:

    "<GATEWAY>_<ENV>_<GATEWAY_TX_ID>"

  Examples:
    "stripe_live_pi_3OvHbc2eZvKYlo2C0123456"
    "braintree_live_ch_1NzMfBLkdIwHuTiX6ZtV3q"
    "paypal_sandbox_PAYID-MVTEST123456789AB"
    "square_live_T5GbLa9rVFm0001"
  """

  require Logger

  @supported_gateways ~w(stripe braintree paypal square adyen worldpay)
  @environments       ~w(live sandbox staging)

  @doc """
  Parses a composite transaction reference string into its component parts.

  Returns `{:ok, map}` on success or `{:error, reason}` when the gateway or
  environment is not in the supported set.
  """

  def parse(ref) when is_binary(ref) do
    parts      = String.split(ref, "_")
    gateway    = Enum.at(parts, 0)
    env        = Enum.at(parts, 1)
    gateway_id = Enum.at(parts, 2)

    with :ok <- validate_gateway(gateway),
         :ok <- validate_environment(env) do
      {:ok, %{
        raw:           ref,
        gateway:       gateway,
        environment:   env,
        gateway_tx_id: gateway_id,
        live?:         env == "live"
      }}
    end
  end

  @doc """
  Parses a list of transaction references, returning `{:ok, results}` and
  `{:error, failures}` partitions.
  """
  def parse_many(refs) when is_list(refs) do
    {ok, errors} =
      refs
      |> Enum.map(&{&1, parse(&1)})
      |> Enum.split_with(fn {_, result} -> match?({:ok, _}, result) end)

    {
      Enum.map(ok,     fn {_, {:ok, info}} -> info end),
      Enum.map(errors, fn {raw, {:error, reason}} -> %{raw: raw, reason: reason} end)
    }
  end

  @doc """
  Reconstructs the composite reference string from its components.
  """
  def build(gateway, env, gateway_tx_id)
      when is_binary(gateway) and is_binary(env) and is_binary(gateway_tx_id) do
    "#{gateway}_#{env}_#{gateway_tx_id}"
  end

  @doc """
  Returns whether a parsed transaction reference belongs to the live environment.
  """
  def live?(%{environment: "live"}), do: true
  def live?(_),                      do: false

  @doc """
  Returns whether a parsed transaction reference belongs to a test/sandbox environment.
  """
  def test?(%{environment: env}) when env in ~w(sandbox staging), do: true
  def test?(_),                                                     do: false

  @doc """
  Returns the dashboard URL for a transaction, given the parsed reference.
  Used for support tooling.
  """
  def dashboard_url(%{gateway: "stripe", environment: "live", gateway_tx_id: id}) do
    {:ok, "https://dashboard.stripe.com/payments/#{id}"}
  end

  def dashboard_url(%{gateway: "stripe", environment: "sandbox", gateway_tx_id: id}) do
    {:ok, "https://dashboard.stripe.com/test/payments/#{id}"}
  end

  def dashboard_url(%{gateway: gateway}) do
    {:error, {:no_dashboard_url, gateway}}
  end

  @doc """
  Logs a structured audit entry for the parsed transaction reference.
  """
  def audit_log(%{gateway: gw, environment: env, gateway_tx_id: id, raw: raw}) do
    Logger.info("Payment reference parsed",
      gateway:       gw,
      environment:   env,
      gateway_tx_id: id,
      raw_ref:       raw
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_gateway(gw) when is_binary(gw) do
    if gw in @supported_gateways do
      :ok
    else
      {:error, {:unsupported_gateway, gw}}
    end
  end

  defp validate_gateway(nil), do: {:error, :missing_gateway}
  defp validate_gateway(_),   do: {:error, :invalid_gateway}

  defp validate_environment(env) when is_binary(env) do
    if env in @environments do
      :ok
    else
      {:error, {:invalid_environment, env}}
    end
  end

  defp validate_environment(nil), do: {:error, :missing_environment}
  defp validate_environment(_),   do: {:error, :invalid_environment}
end
```
