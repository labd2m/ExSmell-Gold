```elixir
defmodule BloomFilter do
  @moduledoc """
  A space-efficient probabilistic membership set using a bit array and
  multiple independent hash functions.

  `member?/2` may return a false positive (reporting an item as present
  when it is not), but never a false negative (reporting an absent item
  as missing). The false-positive probability is a function of the bit
  array size and the number of hash functions; `new/2` computes optimal
  values for a given capacity and target error rate.
  """

  @type t :: %__MODULE__{
          bits: binary(),
          bit_count: pos_integer(),
          hash_count: pos_integer(),
          item_count: non_neg_integer()
        }

  defstruct [:bits, :bit_count, :hash_count, item_count: 0]

  @spec new(pos_integer(), float()) :: t()
  def new(expected_items, false_positive_rate \\ 0.01)
      when is_integer(expected_items) and expected_items > 0 and
             false_positive_rate > 0.0 and false_positive_rate < 1.0 do
    bit_count = optimal_bit_count(expected_items, false_positive_rate)
    hash_count = optimal_hash_count(bit_count, expected_items)
    byte_count = div(bit_count + 7, 8)

    %__MODULE__{
      bits: :binary.copy(<<0>>, byte_count),
      bit_count: bit_count,
      hash_count: hash_count
    }
  end

  @spec add(t(), binary()) :: t()
  def add(%__MODULE__{} = filter, item) when is_binary(item) do
    positions = hash_positions(item, filter.bit_count, filter.hash_count)
    updated_bits = Enum.reduce(positions, filter.bits, &set_bit(&2, &1))
    %{filter | bits: updated_bits, item_count: filter.item_count + 1}
  end

  @spec member?(t(), binary()) :: boolean()
  def member?(%__MODULE__{} = filter, item) when is_binary(item) do
    filter
    |> hash_positions(item)
    |> Enum.all?(&bit_set?(filter.bits, &1))
  end

  @spec false_positive_probability(t()) :: float()
  def false_positive_probability(%__MODULE__{bit_count: m, hash_count: k, item_count: n}) do
    filled = 1.0 - :math.exp(-k * n / m)
    :math.pow(filled, k)
  end

  @spec saturation(t()) :: float()
  def saturation(%__MODULE__{bits: bits, bit_count: m}) do
    set_bits =
      for <<byte::8 <- bits>>, do: Integer.popcount(byte)

    Enum.sum(set_bits) / m
  end

  defp hash_positions(%__MODULE__{bit_count: m, hash_count: k}, item) do
    hash_positions(item, m, k)
  end

  defp hash_positions(item, bit_count, hash_count) do
    Enum.map(0..(hash_count - 1), fn seed ->
      :erlang.phash2({seed, item}, bit_count)
    end)
  end

  defp set_bit(bits, position) do
    byte_idx = div(position, 8)
    bit_idx = rem(position, 8)
    <<before::binary-size(byte_idx), byte::8, rest::binary>> = bits
    <<before::binary, byte ||| 1 <<< (7 - bit_idx), rest::binary>>
  end

  defp bit_set?(bits, position) do
    byte_idx = div(position, 8)
    bit_idx = rem(position, 8)
    <<_::binary-size(byte_idx), byte::8, _::binary>> = bits
    (byte &&& 1 <<< (7 - bit_idx)) != 0
  end

  defp optimal_bit_count(n, p) do
    trunc(-n * :math.log(p) / :math.pow(:math.log(2), 2)) + 1
  end

  defp optimal_hash_count(m, n) do
    max(1, trunc(m / n * :math.log(2)))
  end
end
```
