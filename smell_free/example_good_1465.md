```elixir
defmodule Billing.PaymentMethod do
  @moduledoc """
  Value object representing a stored customer payment method.
  """

  @type t :: %__MODULE__{
          token: String.t(),
          brand: String.t(),
          last_four: String.t(),
          exp_month: pos_integer(),
          exp_year: pos_integer()
        }

  defstruct [:token, :brand, :last_four, :exp_month, :exp_year]
end

defmodule Billing.Charge do
  @moduledoc """
  Represents the result of a completed or failed payment attempt.
  """

  @type status :: :succeeded | :declined | :error
  @type t :: %__MODULE__{
          id: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          status: status(),
          failure_reason: String.t() | nil
        }

  defstruct [:id, :amount_cents, :currency, :status, :failure_reason]
end

defmodule Billing.Gateway do
  @moduledoc """
  Wraps an external payment processor with a clean, typed interface.
  Configuration is injected at call time to allow multi-provider setups.
  """

  alias Billing.{Charge, PaymentMethod}

  @type gateway_opts :: keyword()

  @spec charge(PaymentMethod.t(), pos_integer(), String.t(), gateway_opts()) ::
          {:ok, Charge.t()} | {:error, Charge.t()}
  def charge(%PaymentMethod{} = method, amount_cents, currency, opts)
      when is_integer(amount_cents) and amount_cents > 0 and is_binary(currency) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.get(opts, :base_url, "https://api.payment-provider.example")

    payload = %{
      source: method.token,
      amount: amount_cents,
      currency: currency
    }

    with {:ok, response_body} <- post_charge(base_url, api_key, payload),
         {:ok, charge} <- decode_charge(response_body) do
      {:ok, charge}
    else
      {:error, charge = %Charge{}} -> {:error, charge}
      {:error, reason} -> {:error, build_error_charge(amount_cents, currency, inspect(reason))}
    end
  end

  defp post_charge(base_url, api_key, payload) do
    url = "#{base_url}/v1/charges"
    headers = [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}]

    case Req.post(url, body: Jason.encode!(payload), headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_charge(%{"id" => id, "status" => "succeeded", "amount" => amount, "currency" => cur}) do
    {:ok, %Charge{id: id, amount_cents: amount, currency: cur, status: :succeeded}}
  end

  defp decode_charge(%{"id" => id, "status" => "failed", "failure_message" => reason,
                       "amount" => amount, "currency" => cur}) do
    {:error, %Charge{id: id, amount_cents: amount, currency: cur, status: :declined,
                     failure_reason: reason}}
  end

  defp decode_charge(_body), do: {:error, :unexpected_response}

  defp build_error_charge(amount_cents, currency, reason) do
    %Charge{
      id: nil,
      amount_cents: amount_cents,
      currency: currency,
      status: :error,
      failure_reason: reason
    }
  end
end
```
