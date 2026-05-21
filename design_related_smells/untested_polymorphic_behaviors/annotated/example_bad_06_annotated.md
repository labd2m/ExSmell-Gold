# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Inventory.BarcodeGenerator.prepare_barcode_payload/1`
- **Affected function(s):** `prepare_barcode_payload/1`
- **Short explanation:** `prepare_barcode_payload/1` applies `to_string/1` to the raw SKU
  value without any guard clause or pattern match. The function is intended to accept
  binary SKU strings or atom-based internal codes. Passing an `Integer` SKU (a common
  mistake when the value comes straight from a database integer column) produces a
  numeric string that passes validation silently but generates a barcode encoding the
  wrong symbol set. Passing a `Tuple` (e.g., an `{:ok, sku}` that was not unwrapped)
  raises `Protocol.UndefinedError`, crashing the batch generation job mid-run.

---

```elixir
defmodule Inventory.BarcodeGenerator do
  @moduledoc """
  Generates Code 128 barcode payloads for product SKUs, bin labels,
  and shipment cartons. The encoded binary is passed to an external
  label-printing service via HTTP.

  SKU format contract: uppercase alphanumeric, max 20 characters,
  optionally prefixed with a two-letter category code (e.g., "EL-ABC123").
  """

  require Logger

  @sku_pattern ~r/^[A-Z]{0,2}-?[A-Z0-9]{1,20}$/
  @checksum_modulus 103
  @start_code_b 104
  @stop_code    106

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generates a Code 128 barcode payload binary for a single SKU.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def generate(sku) do
    with {:ok, payload} <- prepare_barcode_payload(sku),
         :ok            <- validate_sku_format(payload),
         encoded        <- encode_code128(payload),
         checksum       <- compute_checksum(encoded) do
      {:ok, finalize(encoded, checksum)}
    end
  end

  @doc """
  Batch-generates barcodes for a list of SKUs. Returns a map of
  `%{sku => {:ok, binary} | {:error, reason}}`.
  """
  def generate_batch(skus) when is_list(skus) do
    Task.async_stream(skus, &{&1, generate(&1)}, max_concurrency: 8, timeout: 5_000)
    |> Stream.map(fn {:ok, {sku, result}} -> {sku, result} end)
    |> Map.new()
  end

  @doc """
  Generates a bin label payload combining the warehouse code and bin ID.
  """
  def generate_bin_label(warehouse_code, bin_id)
      when is_binary(warehouse_code) and is_integer(bin_id) do
    label = "#{warehouse_code}-BIN#{String.pad_leading(Integer.to_string(bin_id), 5, "0")}"
    generate(label)
  end

  # ---------------------------------------------------------------------------
  # Payload preparation
  # ---------------------------------------------------------------------------

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because prepare_barcode_payload/1 calls to_string/1
  # VALIDATION: without any guard clause or pattern match. The function is meant to
  # VALIDATION: accept binary SKU strings or atom-based internal product codes.
  # VALIDATION: - An Atom like :EL_ABC123 implements String.Chars and gets converted
  # VALIDATION:   to "EL_ABC123", silently including underscores that later fail
  # VALIDATION:   the barcode format regex validation—the error is reported at the
  # VALIDATION:   wrong layer (validation, not input coercion).
  # VALIDATION: - An Integer SKU (e.g., 12345, from a DB integer column) produces
  # VALIDATION:   "12345", which passes regex validation and encodes a barcode, but
  # VALIDATION:   the resulting symbol set differs from the expected alphanumeric
  # VALIDATION:   encoding, silently producing an unscannable label.
  # VALIDATION: - A Tuple like {:ok, "EL-ABC"} (an unwrapped result) raises
  # VALIDATION:   Protocol.UndefinedError, crashing the batch job.
  defp prepare_barcode_payload(sku) do
    normalized =
      sku
      |> to_string()
      |> String.upcase()
      |> String.trim()

    {:ok, normalized}
  end
  # VALIDATION: SMELL END

  # ---------------------------------------------------------------------------
  # Code 128 encoding internals
  # ---------------------------------------------------------------------------

  defp validate_sku_format(payload) do
    if Regex.match?(@sku_pattern, payload) do
      :ok
    else
      {:error, {:invalid_sku_format, payload}}
    end
  end

  defp encode_code128(payload) do
    payload
    |> String.to_charlist()
    |> Enum.map(fn char -> char - 32 end)
  end

  defp compute_checksum(code_values) do
    code_values
    |> Enum.with_index(1)
    |> Enum.reduce(@start_code_b, fn {value, index}, acc ->
      acc + value * index
    end)
    |> rem(@checksum_modulus)
  end

  defp finalize(encoded, checksum) do
    [@start_code_b | encoded] ++ [checksum, @stop_code]
  end

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  @doc "Returns true if the given binary is a structurally valid SKU string."
  def valid_sku_string?(sku) when is_binary(sku) do
    Regex.match?(@sku_pattern, String.upcase(sku))
  end

  def valid_sku_string?(_), do: false

  @doc "Strips optional category prefix from a full SKU string."
  def strip_prefix(sku) when is_binary(sku) do
    case String.split(sku, "-", parts: 2) do
      [_prefix, code] -> code
      [code]          -> code
    end
  end
end
```
