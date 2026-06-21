```elixir
defmodule Network.Cidr do
  @moduledoc """
  Parses CIDR notation and checks whether IP addresses fall within a range.

  Both IPv4 (e.g. `192.168.1.0/24`) and IPv6 (e.g. `2001:db8::/32`) ranges
  are supported. Addresses and ranges are represented internally as integers
  for efficient bitwise comparison. The module is pure functional with no
  external dependencies.
  """

  @type t :: %__MODULE__{
          network: non_neg_integer(),
          mask: non_neg_integer(),
          prefix_length: non_neg_integer(),
          family: :v4 | :v6
        }

  defstruct [:network, :mask, :prefix_length, :family]

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_cidr}
  def parse(cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [address_str, prefix_str] ->
        with {:ok, prefix} <- parse_prefix(prefix_str),
             {:ok, {address_int, family}} <- parse_address(address_str),
             {:ok, mask} <- build_mask(prefix, family) do
          network = Bitwise.band(address_int, mask)
          {:ok, %__MODULE__{network: network, mask: mask, prefix_length: prefix, family: family}}
        end

      _ ->
        {:error, :invalid_cidr}
    end
  end

  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{} = cidr, address) when is_binary(address) do
    case parse_address(address) do
      {:ok, {addr_int, family}} when family == cidr.family ->
        Bitwise.band(addr_int, cidr.mask) == cidr.network

      _ ->
        false
    end
  end

  @spec any_match?([t()], String.t()) :: boolean()
  def any_match?(cidrs, address) when is_list(cidrs) and is_binary(address) do
    Enum.any?(cidrs, &contains?(&1, address))
  end

  @spec to_range(t()) :: {non_neg_integer(), non_neg_integer()}
  def to_range(%__MODULE__{network: network, mask: mask}) do
    host_bits = Bitwise.bxor(mask, max_addr_for_mask(mask))
    {network, Bitwise.bor(network, host_bits)}
  end

  @spec address_count(t()) :: pos_integer()
  def address_count(%__MODULE__{prefix_length: prefix, family: :v4}) do
    trunc(:math.pow(2, 32 - prefix))
  end

  def address_count(%__MODULE__{prefix_length: prefix, family: :v6}) do
    trunc(:math.pow(2, 128 - prefix))
  end

  defp parse_prefix(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 and n <= 128 -> {:ok, n}
      _ -> {:error, :invalid_cidr}
    end
  end

  defp parse_address(str) do
    cond do
      String.contains?(str, ":") ->
        case :inet.parse_address(to_charlist(str)) do
          {:ok, tuple} when tuple_size(tuple) == 8 ->
            int = tuple_to_int(tuple, 16)
            {:ok, {int, :v6}}
          _ -> {:error, :invalid_cidr}
        end

      true ->
        case :inet.parse_address(to_charlist(str)) do
          {:ok, tuple} when tuple_size(tuple) == 4 ->
            int = tuple_to_int(tuple, 8)
            {:ok, {int, :v4}}
          _ -> {:error, :invalid_cidr}
        end
    end
  end

  defp build_mask(prefix, :v4) when prefix <= 32 do
    mask = Bitwise.bxor(trunc(:math.pow(2, 32)) - 1, trunc(:math.pow(2, 32 - prefix)) - 1)
    {:ok, mask}
  end

  defp build_mask(prefix, :v6) when prefix <= 128 do
    max = trunc(:math.pow(2, 128)) - 1
    host = trunc(:math.pow(2, 128 - prefix)) - 1
    {:ok, Bitwise.bxor(max, host)}
  end

  defp build_mask(_prefix, _family), do: {:error, :invalid_cidr}

  defp tuple_to_int(tuple, bits_per_element) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, bits_per_element) + part end)
  end

  defp max_addr_for_mask(mask) when mask > 0 do
    bits = floor(:math.log2(mask + 1))
    trunc(:math.pow(2, bits)) - 1
  end
  defp max_addr_for_mask(_), do: 0
end
```
