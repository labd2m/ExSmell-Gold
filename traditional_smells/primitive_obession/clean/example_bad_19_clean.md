```elixir
defmodule Payments.BankAccountService do
  @moduledoc """
  Manages bank account registration, ACH transfer initiation, and
  micro-deposit verification for the payments platform. Handles
  both checking and savings account types for US domestic transfers.
  """

  require Logger

  @supported_account_types ~w(checking savings)
  @ach_routing_length 9

  @spec register_account(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def register_account(owner_id, account_number, routing_number, account_type) do
    with :ok <- validate_account(account_number, routing_number, account_type) do
      record = %{
        id: generate_account_id(),
        owner_id: owner_id,
        account_number_masked: mask_account(account_number),
        routing_number: routing_number,
        account_type: account_type,
        verified: false,
        registered_at: DateTime.utc_now()
      }

      Logger.info(
        "Bank account registered for owner #{owner_id}: " <>
          "#{mask_account(account_number)} (#{account_type})"
      )

      {:ok, record}
    end
  end

  @spec validate_account(String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def validate_account(account_number, routing_number, account_type) do
    with :ok <- check_account_number(account_number),
         :ok <- check_routing_number(routing_number),
         :ok <- check_account_type(account_type),
         :ok <- verify_aba_checksum(routing_number) do
      :ok
    end
  end

  @spec initiate_transfer(String.t(), String.t(), String.t(), String.t(), float()) ::
          {:ok, map()} | {:error, String.t()}
  def initiate_transfer(account_number, routing_number, account_type, direction, amount_usd) do
    with :ok <- validate_account(account_number, routing_number, account_type),
         :ok <- validate_transfer_direction(direction),
         :ok <- validate_transfer_amount(amount_usd) do
      transfer = %{
        transfer_id: generate_account_id(),
        account_masked: mask_account(account_number),
        routing_number: routing_number,
        account_type: account_type,
        direction: direction,
        amount_usd: Float.round(amount_usd, 2),
        status: "pending",
        initiated_at: DateTime.utc_now()
      }

      Logger.info(
        "ACH #{direction} transfer initiated: $#{amount_usd} " <>
          "#{account_type} #{mask_account(account_number)}"
      )

      {:ok, transfer}
    end
  end

  @spec mask_account(String.t()) :: String.t()
  def mask_account(account_number) do
    len = String.length(account_number)

    if len <= 4 do
      String.duplicate("*", len)
    else
      String.duplicate("*", len - 4) <> String.slice(account_number, -4, 4)
    end
  end

  @spec accounts_match?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def accounts_match?(acct_a, routing_a, acct_b, routing_b) do
    acct_a == acct_b and routing_a == routing_b
  end

  defp check_account_number(account_number) do
    digits = String.replace(account_number, ~r/\D/, "")

    if String.length(digits) in 4..17 do
      :ok
    else
      {:error, "Account number must be 4–17 digits, got #{String.length(digits)}"}
    end
  end

  defp check_routing_number(routing_number) do
    digits = String.replace(routing_number, ~r/\D/, "")

    if String.length(digits) == @ach_routing_length do
      :ok
    else
      {:error, "Routing number must be #{@ach_routing_length} digits, got #{String.length(digits)}"}
    end
  end

  defp check_account_type(account_type) do
    if account_type in @supported_account_types do
      :ok
    else
      {:error,
       "Unsupported account type '#{account_type}'. Supported: #{Enum.join(@supported_account_types, ", ")}"}
    end
  end

  defp verify_aba_checksum(routing_number) do
    digits = routing_number |> String.replace(~r/\D/, "") |> String.graphemes() |> Enum.map(&String.to_integer/1)

    if length(digits) != 9 do
      {:error, "Cannot verify ABA checksum: invalid routing number length"}
    else
      [d0, d1, d2, d3, d4, d5, d6, d7, d8] = digits
      checksum = 3 * (d0 + d3 + d6) + 7 * (d1 + d4 + d7) + (d2 + d5 + d8)

      if rem(checksum, 10) == 0 do
        :ok
      else
        {:error, "Routing number #{routing_number} failed ABA checksum verification"}
      end
    end
  end

  defp validate_transfer_direction(direction) do
    if direction in ["credit", "debit"] do
      :ok
    else
      {:error, "Transfer direction must be 'credit' or 'debit', got '#{direction}'"}
    end
  end

  defp validate_transfer_amount(amount) do
    cond do
      amount <= 0.0 -> {:error, "Transfer amount must be positive"}
      amount > 1_000_000.0 -> {:error, "Transfer amount exceeds single-transaction limit"}
      true -> :ok
    end
  end

  defp generate_account_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
