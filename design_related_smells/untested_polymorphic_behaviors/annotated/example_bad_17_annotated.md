# Annotated Bad Example 17: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Payments.TransactionLog.format_metadata_value/1`
- **Affected function(s)**: `format_metadata_value/1`
- **Short explanation**: The function uses `inspect/1` on its argument without any guard clause or type restriction. `inspect/1` relies on the `Inspect` protocol, which has a default implementation (via `Any`) that works for all types but produces Elixir-syntax debug representations (e.g., `"%{key: val}"`) for maps, lists, and tuples. This means passing structured data silently produces cryptic or misleading strings in the payment metadata log, rather than raising an error at the boundary. The function should either restrict the input to expected scalar types or document and test all accepted types explicitly.

## Code

```elixir
defmodule Payments.TransactionLog do
  @moduledoc """
  Records structured transaction events for audit and reconciliation.
  Entries are written to the append-only transaction log table and later
  consumed by the finance team's reporting pipeline.
  """

  @log_version "1.0"
  @max_metadata_entries 20
  @max_metadata_key_length 64
  @max_metadata_value_length 256

  @type event_type ::
          :charge_initiated
          | :charge_succeeded
          | :charge_failed
          | :refund_requested
          | :refund_processed
          | :chargeback_received

  @doc """
  Builds a structured log entry map for a transaction event.
  """
  def build_entry(event_type, transaction_id, metadata \\ %{})
      when is_atom(event_type) and is_binary(transaction_id) and is_map(metadata) do
    %{
      version: @log_version,
      event_type: Atom.to_string(event_type),
      transaction_id: transaction_id,
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: sanitize_metadata(metadata)
    }
  end

  @doc """
  Sanitizes a metadata map by enforcing key and value length limits
  and serializing each value to its log-safe string form.
  """
  def sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.take(@max_metadata_entries)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key = serialize_metadata_key(k)
      value = format_metadata_value(v)

      if String.length(key) <= @max_metadata_key_length and
           String.length(value) <= @max_metadata_value_length do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp serialize_metadata_key(key) when is_atom(key), do: Atom.to_string(key)
  defp serialize_metadata_key(key) when is_binary(key), do: key

  @doc """
  Formats a single metadata value for safe storage in the transaction log.
  All values are stored as strings to maintain a uniform log schema.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `inspect/1` depends on the `Inspect`
  # protocol. Although `Inspect` has a fallback implementation for `Any`, calling
  # `inspect/1` on structured data like a `Map` or a `List` silently produces
  # Elixir-syntax debug strings (e.g., `"%{amount: 100}"`) that are stored in
  # the audit log. This is semantically wrong for a payment metadata log field
  # and could mislead finance auditors. There is no guard clause, so every type
  # is accepted silently without error, making the function's valid input domain
  # completely untested and undocumented.
  def format_metadata_value(value) do
    inspect(value)
  end
  # VALIDATION: SMELL END

  @doc """
  Appends an entry to the transaction log. In production this writes to the DB;
  here it returns the entry for testing purposes.
  """
  def append_entry(entry) when is_map(entry) do
    # In production: Repo.insert!(TransactionLogEntry.changeset(entry))
    {:ok, entry}
  end

  @doc """
  Records a successful charge event.
  """
  def record_charge_success(transaction_id, amount_cents, currency, gateway_ref)
      when is_binary(transaction_id) and is_integer(amount_cents) and
             is_binary(currency) and is_binary(gateway_ref) do
    metadata = %{
      amount_cents: amount_cents,
      currency: currency,
      gateway_ref: gateway_ref
    }

    build_entry(:charge_succeeded, transaction_id, metadata)
    |> append_entry()
  end

  @doc """
  Records a failed charge event with the failure reason.
  """
  def record_charge_failure(transaction_id, reason, gateway_code)
      when is_binary(transaction_id) and is_binary(reason) and is_binary(gateway_code) do
    metadata = %{
      failure_reason: reason,
      gateway_code: gateway_code
    }

    build_entry(:charge_failed, transaction_id, metadata)
    |> append_entry()
  end

  @doc """
  Records a refund processing event.
  """
  def record_refund(transaction_id, refund_id, amount_cents)
      when is_binary(transaction_id) and is_binary(refund_id) and is_integer(amount_cents) do
    metadata = %{
      refund_id: refund_id,
      amount_cents: amount_cents
    }

    build_entry(:refund_processed, transaction_id, metadata)
    |> append_entry()
  end
end
```
