# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Payments.ReferenceBuilder.build_idempotency_key/1`
- **Affected function(s):** `build_idempotency_key/1`
- **Short explanation:** `build_idempotency_key/1` calls `to_string/1` on each part of the key
  components list without guard clauses. The function iterates over a keyword list of
  arbitrary component values and concatenates their string representations. Numeric and atom
  values silently produce keys that look correct but may collide (e.g., integer `123` and
  string `"123"` produce the same key segment). Passing a `Map` or nested struct as a
  component raises `Protocol.UndefinedError`, crashing a payment attempt and potentially
  leaving a charge in an unknown state.

---

```elixir
defmodule Payments.ReferenceBuilder do
  @moduledoc """
  Constructs idempotency keys and human-readable payment references
  used when submitting charges to the payment gateway.

  Idempotency keys must be stable across retries: given the same
  logical payment intent, the same key must always be produced.
  Keys are scoped per merchant account and have a 24-hour TTL on
  the gateway side.
  """

  @key_separator ":"
  @reference_separator "-"
  @max_key_length 255

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds a stable idempotency key for a payment intent.

  ## Parameters
    * `components` - keyword list of named key parts, e.g.:
      `[merchant_id: "M123", order_id: "ORD-456", attempt: 1]`

  ## Examples

      iex> Payments.ReferenceBuilder.build_idempotency_key(
      ...>   merchant_id: "M123", order_id: "ORD-456", attempt: 1
      ...> )
      {:ok, "merchant_id:M123|order_id:ORD-456|attempt:1"}
  """
  def build_idempotency_key(components) when is_list(components) do
    # VALIDATION: SMELL START - Untested polymorphic behaviors
    # VALIDATION: This is a smell because build_idempotency_key/1 calls to_string/1
    # VALIDATION: on every component value without any guard clause or pattern
    # VALIDATION: matching. The function is designed to accept strings, integers,
    # VALIDATION: and atoms as component values. In practice:
    # VALIDATION: - Integer 1 and binary "1" produce identical key segments,
    # VALIDATION:   silently creating key collisions between payment attempts that
    # VALIDATION:   should be distinct (e.g., attempt number vs attempt string).
    # VALIDATION: - An Atom like :pending silently becomes "pending", which may
    # VALIDATION:   or may not be meaningful; the caller has no enforcement.
    # VALIDATION: - A nested Map (e.g., if the caller accidentally passes a full
    # VALIDATION:   metadata struct as a component) raises Protocol.UndefinedError,
    # VALIDATION:   crashing the payment submission at the key-construction step
    # VALIDATION:   and leaving the gateway call never made—yet the order may
    # VALIDATION:   have already been marked as "processing" in the database.
    key =
      components
      |> Enum.map(fn {name, value} ->
        "#{name}#{@key_separator}#{to_string(value)}"
      end)
      |> Enum.join("|")
    # VALIDATION: SMELL END

    if String.length(key) > @max_key_length do
      {:error, {:key_too_long, String.length(key)}}
    else
      {:ok, key}
    end
  end

  @doc """
  Builds a human-readable payment reference number shown on receipts
  and statements. Format: `<PREFIX>-<DATE>-<SEQUENCE>`.

  ## Examples

      iex> Payments.ReferenceBuilder.build_reference("INV", ~D[2024-03-15], 4821)
      "INV-20240315-004821"
  """
  def build_reference(prefix, %Date{} = date, sequence)
      when is_binary(prefix) and is_integer(sequence) and sequence >= 0 do
    date_part = Calendar.strftime(date, "%Y%m%d")
    seq_part  = String.pad_leading(Integer.to_string(sequence), 6, "0")

    ref = Enum.join([String.upcase(prefix), date_part, seq_part], @reference_separator)
    {:ok, ref}
  end

  @doc """
  Builds a gateway correlation ID by hashing the idempotency key.
  Used for tracing requests in gateway logs.
  """
  def build_correlation_id(idempotency_key) when is_binary(idempotency_key) do
    hash =
      :crypto.hash(:sha256, idempotency_key)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    "corr_#{hash}"
  end

  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------

  @doc "Returns true if the key contains only printable ASCII characters."
  def valid_key_format?(key) when is_binary(key) do
    Regex.match?(~r/^[\x20-\x7E]+$/, key)
  end

  def valid_key_format?(_), do: false

  @doc "Parses a reference string back into its components."
  def parse_reference(ref) when is_binary(ref) do
    case String.split(ref, @reference_separator) do
      [prefix, date_str, seq_str] ->
        with {:ok, date} <- Date.from_iso8601(format_date_string(date_str)),
             {seq, ""} <- Integer.parse(seq_str) do
          {:ok, %{prefix: prefix, date: date, sequence: seq}}
        else
          _ -> {:error, :invalid_reference_format}
        end

      _ ->
        {:error, :invalid_reference_format}
    end
  end

  defp format_date_string(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{m}-#{d}"
  end

  defp format_date_string(_), do: "invalid"
end
```
