# Annotated Example 05 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro mask_card_number/1` inside `Payments.CardUtils`
- **Affected function(s):** `mask_card_number/1`
- **Short explanation:** The macro masks a PAN string using only string slicing and concatenation — all runtime operations. No compile-time transformation is involved, making the macro an overcomplicated replacement for a regular function.

---

```elixir
defmodule Payments.CardUtils do
  @moduledoc """
  Utility functions for handling payment card data safely,
  including masking, BIN extraction, and card-type detection.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because mask_card_number/1 only slices a
  # runtime string and concatenates parts — purely a runtime string operation.
  # There is no reason to use a macro; a regular function is simpler and safer.
  defmacro mask_card_number(pan) do
    quote do
      number = unquote(pan)
      last_four = String.slice(number, -4, 4)
      String.duplicate("*", max(String.length(number) - 4, 0)) <> last_four
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Extracts the Bank Identification Number (first 6 digits) from a PAN.
  """
  @spec extract_bin(String.t()) :: String.t()
  def extract_bin(pan) when is_binary(pan) do
    String.slice(pan, 0, 6)
  end

  @doc """
  Detects the card network based on the BIN prefix.
  Returns one of: `:visa`, `:mastercard`, `:amex`, `:discover`, or `:unknown`.
  """
  @spec detect_network(String.t()) :: atom()
  def detect_network(pan) when is_binary(pan) do
    bin = extract_bin(pan)

    cond do
      String.starts_with?(bin, "4") -> :visa
      String.match?(bin, ~r/^5[1-5]/) -> :mastercard
      String.match?(bin, ~r/^3[47]/) -> :amex
      String.match?(bin, ~r/^6(?:011|5)/) -> :discover
      true -> :unknown
    end
  end

  @doc """
  Validates basic structural correctness of a card number using Luhn algorithm.
  """
  @spec luhn_valid?(String.t()) :: boolean()
  def luhn_valid?(pan) when is_binary(pan) do
    digits =
      pan
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, idx}, acc ->
        if rem(idx, 2) == 1 do
          doubled = digit * 2
          acc + if doubled > 9, do: doubled - 9, else: doubled
        else
          acc + digit
        end
      end)

    rem(sum, 10) == 0
  end
end

defmodule Payments.TransactionLogger do
  @moduledoc """
  Responsible for creating audit log entries for payment transactions.
  All sensitive card data is masked before being written to the log.
  """

  require Payments.CardUtils

  alias Payments.CardUtils

  @doc """
  Builds a log entry map for a completed transaction.
  Masks the PAN before storing to ensure PCI-DSS compliance in logs.
  """
  @spec build_log_entry(map()) :: map()
  def build_log_entry(%{pan: pan, amount_cents: amount, status: status, reference: ref}) do
    %{
      reference: ref,
      masked_pan: CardUtils.mask_card_number(pan),
      card_network: CardUtils.detect_network(pan),
      amount_cents: amount,
      status: status,
      logged_at: DateTime.utc_now()
    }
  end

  @doc """
  Formats a log entry as a single-line audit string for append-only log files.
  """
  @spec format_audit_line(map()) :: String.t()
  def format_audit_line(%{reference: ref, masked_pan: pan, amount_cents: amount, status: status, logged_at: ts}) do
    timestamp = DateTime.to_iso8601(ts)
    dollars = "#{div(amount, 100)}.#{rem(amount, 100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
    "[#{timestamp}] ref=#{ref} pan=#{pan} amount=#{dollars} status=#{status}"
  end

  @doc """
  Writes a batch of transaction maps to the audit log, returning the count written.
  """
  @spec log_transactions(list(map()), (String.t() -> :ok)) :: non_neg_integer()
  def log_transactions(transactions, write_fn) do
    transactions
    |> Enum.map(&build_log_entry/1)
    |> Enum.map(&format_audit_line/1)
    |> Enum.each(write_fn)

    length(transactions)
  end
end
```
