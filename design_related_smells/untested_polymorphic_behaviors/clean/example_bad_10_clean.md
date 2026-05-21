```elixir
defmodule Shipping.AddressSerializer do
  @moduledoc """
  Serializes shipping address structs into the flat JSON payload format
  required by the carrier API (v3). All field values must be plain strings;
  nested structures must be flattened before serialization.

  Carrier API field limits:
    - `name`:      max 35 chars
    - `line1`:     max 35 chars
    - `line2`:     max 35 chars (optional)
    - `city`:      max 30 chars
    - `state`:     2-letter ISO code
    - `postal`:    max 10 chars
    - `country`:   2-letter ISO code
    - `phone`:     max 15 chars (optional)
  """

  alias Shipping.Address

  @required_fields ~w[name line1 city state postal country]a
  @optional_fields ~w[line2 phone]a
  @all_fields @required_fields ++ @optional_fields

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Serializes an `Address` struct to a carrier-API-ready map of string values.
  Returns `{:ok, map}` or `{:error, [{field, reason}]}`.
  """
  def serialize(%Address{} = address) do
    with :ok <- validate_required(address) do
      payload =
        @all_fields
        |> Enum.reduce(%{}, fn field, acc ->
          case Map.get(address, field) do
            nil   -> acc
            value -> Map.put(acc, Atom.to_string(field), encode_field(value))
          end
        end)

      {:ok, payload}
    end
  end

  @doc """
  Serializes a list of addresses in batch. Returns a list of
  `{:ok, map} | {:error, reasons}` in the same order.
  """
  def serialize_batch(addresses) when is_list(addresses) do
    Enum.map(addresses, &serialize/1)
  end

  @doc """
  Builds the full carrier API request body for a shipment, combining
  sender and recipient address payloads.
  """
  def build_shipment_payload(sender, recipient, opts \\ []) do
    with {:ok, from_payload} <- serialize(sender),
         {:ok, to_payload}   <- serialize(recipient) do
      body = %{
        "shipFrom" => from_payload,
        "shipTo"   => to_payload,
        "service"  => Keyword.get(opts, :service, "ground"),
        "currency" => Keyword.get(opts, :currency, "USD")
      }

      {:ok, body}
    end
  end

  defp encode_field(value) do
    value
    |> inspect()
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_required(%Address{} = address) do
    errors =
      @required_fields
      |> Enum.flat_map(fn field ->
        case Map.get(address, field) do
          nil -> [{field, :missing}]
          ""  -> [{field, :blank}]
          _   -> []
        end
      end)

    case errors do
      []     -> :ok
      errors -> {:error, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Field-level sanitization
  # ---------------------------------------------------------------------------

  @doc "Strips non-printable characters from an address field string."
  def sanitize_field(value) when is_binary(value) do
    Regex.replace(~r/[^\x20-\x7E]/, value, "")
    |> String.trim()
  end

  @doc "Truncates a field value to the carrier's maximum allowed length."
  def truncate_field(value, max_length)
      when is_binary(value) and is_integer(max_length) and max_length > 0 do
    String.slice(value, 0, max_length)
  end

  @doc """
  Returns a normalized state code. Accepts full state names or 2-letter codes.
  Only US states are currently supported.
  """
  def normalize_state(state) when is_binary(state) do
    case String.upcase(String.trim(state)) do
      code when byte_size(code) == 2 -> {:ok, code}
      full_name -> lookup_state_code(full_name)
    end
  end

  defp lookup_state_code("CALIFORNIA"), do: {:ok, "CA"}
  defp lookup_state_code("NEW YORK"),   do: {:ok, "NY"}
  defp lookup_state_code("TEXAS"),      do: {:ok, "TX"}
  defp lookup_state_code(_),            do: {:error, :unknown_state}
end
```
