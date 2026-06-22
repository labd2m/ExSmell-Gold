**File:** `example_good_1057.md`

```elixir
defmodule Payments.Gateway do
  @moduledoc """
  Provides charge and refund operations against a configured payment provider.
  All operations return tagged tuples; raise-variant functions are available
  for contexts where callers prefer to pattern-match on success only.
  """

  alias Payments.{Charge, Refund, ProviderClient}

  @type charge_params :: %{
          amount_cents: pos_integer(),
          currency: String.t(),
          source_token: String.t(),
          idempotency_key: String.t()
        }

  @type refund_params :: %{
          charge_id: String.t(),
          amount_cents: pos_integer(),
          reason: :duplicate | :fraudulent | :requested_by_customer
        }

  @spec charge(charge_params(), keyword()) :: {:ok, Charge.t()} | {:error, term()}
  def charge(%{amount_cents: cents} = params, opts \\ []) when is_integer(cents) and cents > 0 do
    timeout = Keyword.get(opts, :timeout, 15_000)

    params
    |> build_charge_request()
    |> ProviderClient.post("/charges", timeout: timeout)
    |> parse_charge_response()
  end

  @spec charge!(charge_params(), keyword()) :: Charge.t()
  def charge!(params, opts \\ []) do
    case charge(params, opts) do
      {:ok, charge} -> charge
      {:error, reason} -> raise Payments.GatewayError, reason: reason
    end
  end

  @spec refund(refund_params(), keyword()) :: {:ok, Refund.t()} | {:error, term()}
  def refund(%{charge_id: id, amount_cents: cents} = params, opts \\ [])
      when is_binary(id) and is_integer(cents) and cents > 0 do
    timeout = Keyword.get(opts, :timeout, 15_000)

    params
    |> build_refund_request()
    |> ProviderClient.post("/refunds", timeout: timeout)
    |> parse_refund_response()
  end

  @spec refund!(refund_params(), keyword()) :: Refund.t()
  def refund!(params, opts \\ []) do
    case refund(params, opts) do
      {:ok, refund} -> refund
      {:error, reason} -> raise Payments.GatewayError, reason: reason
    end
  end

  defp build_charge_request(%{
         amount_cents: cents,
         currency: currency,
         source_token: token,
         idempotency_key: key
       }) do
    %{
      amount: cents,
      currency: String.downcase(currency),
      source: token,
      idempotency_key: key
    }
  end

  defp build_refund_request(%{charge_id: id, amount_cents: cents, reason: reason}) do
    %{charge: id, amount: cents, reason: Atom.to_string(reason)}
  end

  defp parse_charge_response({:ok, %{"id" => id, "status" => "succeeded"} = body}) do
    charge = %Charge{
      id: id,
      amount_cents: body["amount"],
      currency: body["currency"],
      status: :succeeded,
      created_at: DateTime.from_unix!(body["created"])
    }

    {:ok, charge}
  end

  defp parse_charge_response({:ok, %{"status" => status, "failure_code" => code}}) do
    {:error, {:charge_failed, status, code}}
  end

  defp parse_charge_response({:error, reason}) do
    {:error, {:provider_error, reason}}
  end

  defp parse_refund_response({:ok, %{"id" => id, "status" => "succeeded"} = body}) do
    refund = %Refund{
      id: id,
      charge_id: body["charge"],
      amount_cents: body["amount"],
      status: :succeeded
    }

    {:ok, refund}
  end

  defp parse_refund_response({:ok, %{"status" => status}}) do
    {:error, {:refund_failed, status}}
  end

  defp parse_refund_response({:error, reason}) do
    {:error, {:provider_error, reason}}
  end
end
```
