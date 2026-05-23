```elixir
defmodule Payments.CardVault do
  @moduledoc """
  Secure card data handling: tokenization, network detection, PAN masking,
  and pre-submission validation. All raw card data is held transiently
  in memory only; persisted tokens reference the vault only.
  """

  require Logger

  alias Payments.Repo
  alias Payments.Schema.{VaultToken, PaymentMethod}
  alias Payments.CryptoService

  @luhn_weights [1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2]


  @spec tokenize_card(String.t(), integer(), integer(), String.t()) ::
          {:ok, VaultToken.t()} | {:error, term()}
  def tokenize_card(pan, expiry_month, expiry_year, cvv)
      when is_binary(pan) and is_integer(expiry_month) and
           is_integer(expiry_year) and is_binary(cvv) do
    with :ok <- validate_card(pan, expiry_month, expiry_year),
         network <- detect_card_network(pan),
         {:ok, token_value} <- CryptoService.encrypt_pan(pan),
         last_four <- String.slice(pan, -4, 4) do
      attrs = %{
        token: token_value,
        last_four: last_four,
        expiry_month: expiry_month,
        expiry_year: expiry_year,
        network: network,
        fingerprint: fingerprint_pan(pan),
        created_at: DateTime.utc_now()
      }

      case %VaultToken{} |> VaultToken.changeset(attrs) |> Repo.insert() do
        {:ok, vault_token} ->
          Logger.info("Card tokenized: network=#{network} last4=#{last_four} exp=#{expiry_month}/#{expiry_year}")
          {:ok, vault_token}

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  @spec detect_card_network(String.t()) :: atom()
  def detect_card_network(pan) when is_binary(pan) do
    cond do
      Regex.match?(~r/^4/, pan) -> :visa
      Regex.match?(~r/^5[1-5]/, pan) -> :mastercard
      Regex.match?(~r/^3[47]/, pan) -> :amex
      Regex.match?(~r/^6(?:011|5)/, pan) -> :discover
      Regex.match?(~r/^(?:636368|438935|504175|451416)/, pan) -> :elo
      true -> :unknown
    end
  end

  @spec mask_pan(String.t()) :: String.t()
  def mask_pan(pan) when is_binary(pan) do
    len = String.length(pan)
    first_six = String.slice(pan, 0, 6)
    last_four = String.slice(pan, -4, 4)
    middle = String.duplicate("*", len - 10)
    "#{first_six}#{middle}#{last_four}"
  end

  @spec validate_card(String.t(), integer(), integer()) ::
          :ok | {:error, term()}
  def validate_card(pan, expiry_month, expiry_year)
      when is_binary(pan) and is_integer(expiry_month) and is_integer(expiry_year) do
    cond do
      not luhn_valid?(pan) ->
        {:error, :invalid_pan}

      expiry_month < 1 or expiry_month > 12 ->
        {:error, {:invalid_expiry_month, expiry_month}}

      {expiry_year, expiry_month} < {Date.utc_today().year, Date.utc_today().month} ->
        {:error, :card_expired}

      String.length(pan) not in 13..19 ->
        {:error, {:invalid_pan_length, String.length(pan)}}

      true ->
        :ok
    end
  end

  @spec save_to_customer(PaymentMethod.t(), String.t(), integer(), integer()) ::
          {:ok, PaymentMethod.t()} | {:error, term()}
  def save_to_customer(%PaymentMethod{} = pm, pan, expiry_month, expiry_year)
      when is_binary(pan) and is_integer(expiry_month) and is_integer(expiry_year) do
    with :ok <- validate_card(pan, expiry_month, expiry_year),
         {:ok, vault_token} <- tokenize_card(pan, expiry_month, expiry_year, "") do
      pm
      |> PaymentMethod.changeset(%{
        vault_token_id: vault_token.id,
        expiry_month: expiry_month,
        expiry_year: expiry_year,
        last_four: String.slice(pan, -4, 4),
        network: Atom.to_string(detect_card_network(pan))
      })
      |> Repo.update()
    end
  end


  ## Private helpers

  defp luhn_valid?(pan) do
    digits =
      pan
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, idx}, acc ->
        d = if rem(idx, 2) == 1, do: digit * 2, else: digit
        acc + (if d > 9, do: d - 9, else: d)
      end)

    rem(sum, 10) == 0
  end

  defp fingerprint_pan(pan) do
    :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)
  end
end
```