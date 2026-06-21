```elixir
defmodule Encoding.Base62 do
  @moduledoc """
  Encodes and decodes non-negative integers to and from Base62 strings.
  Base62 uses characters `[0-9A-Za-z]`, making the output URL-safe without
  percent-encoding. Common applications include short URL keys, token
  generation, and compact numeric IDs.
  """

  @alphabet ~c(0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz)
  @base length(@alphabet)
  @char_to_value Map.new(Enum.with_index(@alphabet), fn {char, idx} -> {char, idx} end)

  @doc """
  Encodes a non-negative integer into a Base62 string.
  Returns `{:error, :negative_input}` for negative integers.
  """
  @spec encode(non_neg_integer()) :: {:ok, String.t()} | {:error, :negative_input}
  def encode(n) when is_integer(n) and n < 0, do: {:error, :negative_input}
  def encode(0), do: {:ok, <<Enum.at(@alphabet, 0)>>}

  def encode(n) when is_integer(n) and n > 0 do
    {:ok, encode_digits(n, [])}
  end

  @doc """
  Decodes a Base62 string back to a non-negative integer.
  Returns `{:error, :invalid_character}` when the string contains characters
  outside the Base62 alphabet.
  """
  @spec decode(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_character}
  def decode(str) when is_binary(str) do
    str
    |> String.to_charlist()
    |> decode_charlist(0)
  end

  @doc "Encodes a binary by first interpreting it as a big-endian unsigned integer."
  @spec encode_bytes(binary()) :: {:ok, String.t()} | {:error, :negative_input}
  def encode_bytes(binary) when is_binary(binary) do
    n = :binary.decode_unsigned(binary, :big)
    encode(n)
  end

  @doc """
  Decodes a Base62 string back to a binary with at least `min_bytes` bytes,
  left-padding with zeroes if necessary.
  """
  @spec decode_bytes(String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_character}
  def decode_bytes(str, min_bytes \\ 1) when is_binary(str) and is_integer(min_bytes) do
    case decode(str) do
      {:ok, n} ->
        raw = :binary.encode_unsigned(n, :big)
        padded = pad_binary(raw, min_bytes)
        {:ok, padded}

      {:error, _} = err ->
        err
    end
  end

  defp encode_digits(0, acc), do: List.to_string(acc)

  defp encode_digits(n, acc) do
    digit = Enum.at(@alphabet, rem(n, @base))
    encode_digits(div(n, @base), [digit | acc])
  end

  defp decode_charlist([], acc), do: {:ok, acc}

  defp decode_charlist([char | rest], acc) do
    case Map.get(@char_to_value, char) do
      nil -> {:error, :invalid_character}
      value -> decode_charlist(rest, acc * @base + value)
    end
  end

  defp pad_binary(binary, min_bytes) when byte_size(binary) >= min_bytes, do: binary

  defp pad_binary(binary, min_bytes) do
    pad_size = min_bytes - byte_size(binary)
    :binary.copy(<<0>>, pad_size) <> binary
  end
end
```
