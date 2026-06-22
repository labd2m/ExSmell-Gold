```elixir
defmodule Integrations.StripeClient do
  @moduledoc """
  Thin HTTP client for the Stripe Charges API.

  Each function accepts explicit connection configuration rather than
  reading from global application environment, enabling per-call key rotation
  and straightforward testing with mock configs.
  """

  alias Integrations.StripeClient.{Config, HttpAdapter, ResponseParser}

  @type charge_params :: %{
          amount: pos_integer(),
          currency: String.t(),
          source: String.t(),
          description: String.t()
        }

  @type stripe_charge :: %{
          id: String.t(),
          amount: pos_integer(),
          status: String.t(),
          created: integer()
        }

  @doc """
  Creates a charge via the Stripe API.

  `config` must be a `%Config{}` containing the secret key and base URL.
  """
  @spec create_charge(charge_params(), Config.t()) ::
          {:ok, stripe_charge()} | {:error, String.t()}
  def create_charge(params, %Config{} = config) do
    with {:ok, validated} <- validate_charge_params(params),
         {:ok, response} <- HttpAdapter.post(config, "/v1/charges", validated),
         {:ok, charge} <- ResponseParser.parse_charge(response) do
      {:ok, charge}
    end
  end

  @doc """
  Retrieves a charge by its Stripe ID.
  """
  @spec get_charge(String.t(), Config.t()) :: {:ok, stripe_charge()} | {:error, String.t()}
  def get_charge(charge_id, %Config{} = config) when is_binary(charge_id) do
    with {:ok, response} <- HttpAdapter.get(config, "/v1/charges/#{charge_id}"),
         {:ok, charge} <- ResponseParser.parse_charge(response) do
      {:ok, charge}
    end
  end

  @doc """
  Refunds a charge either fully or partially.
  """
  @spec refund_charge(String.t(), pos_integer() | :full, Config.t()) ::
          {:ok, map()} | {:error, String.t()}
  def refund_charge(charge_id, :full, %Config{} = config) when is_binary(charge_id) do
    with {:ok, response} <- HttpAdapter.post(config, "/v1/refunds", %{charge: charge_id}),
         {:ok, refund} <- ResponseParser.parse_refund(response) do
      {:ok, refund}
    end
  end

  def refund_charge(charge_id, amount, %Config{} = config)
      when is_binary(charge_id) and is_integer(amount) and amount > 0 do
    with {:ok, response} <-
           HttpAdapter.post(config, "/v1/refunds", %{charge: charge_id, amount: amount}),
         {:ok, refund} <- ResponseParser.parse_refund(response) do
      {:ok, refund}
    end
  end

  defp validate_charge_params(%{amount: a, currency: c, source: s, description: d})
       when is_integer(a) and a > 0 and is_binary(c) and is_binary(s) and is_binary(d) do
    {:ok, %{amount: a, currency: c, source: s, description: d}}
  end

  defp validate_charge_params(_), do: {:error, "invalid charge params"}
end

defmodule Integrations.StripeClient.Config do
  @moduledoc "Connection configuration for the Stripe API client."

  @enforce_keys [:secret_key, :base_url]
  defstruct [:secret_key, :base_url, timeout_ms: 5_000]

  @type t :: %__MODULE__{
          secret_key: String.t(),
          base_url: String.t(),
          timeout_ms: pos_integer()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(secret_key, opts \\ []) when is_binary(secret_key) do
    %__MODULE__{
      secret_key: secret_key,
      base_url: Keyword.get(opts, :base_url, "https://api.stripe.com"),
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
    }
  end
end
```
