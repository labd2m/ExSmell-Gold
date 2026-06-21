```elixir
defmodule Crypto.Hkdf do
  @moduledoc """
  HMAC-based Extract-and-Expand Key Derivation Function (RFC 5869).

  HKDF derives one or more cryptographically strong keys from a single
  input keying material (IKM) such as a shared secret or master key.
  Domain separation via the `info` parameter ensures that keys derived
  for different purposes (signing, encryption, MAC) are independent even
  when produced from the same IKM.
  """

  @type hash_algo :: :sha256 | :sha384 | :sha512

  @hash_lengths %{sha256: 32, sha384: 48, sha512: 64}

  @spec extract(binary(), binary(), hash_algo()) :: binary()
  def extract(ikm, salt \\ "", hash \\ :sha256)
      when is_binary(ikm) and is_binary(salt) and is_atom(hash) do
    effective_salt = if salt == "", do: :binary.copy(<<0>>, hash_length(hash)), else: salt
    :crypto.mac(:hmac, hash, effective_salt, ikm)
  end

  @spec expand(binary(), binary(), pos_integer(), hash_algo()) :: binary()
  def expand(prk, info \\ "", length, hash \\ :sha256)
      when is_binary(prk) and is_binary(info) and is_integer(length) and length > 0 do
    hash_len = hash_length(hash)
    max_length = 255 * hash_len

    if length > max_length do
      raise ArgumentError, "Requested length #{length} exceeds HKDF maximum of #{max_length}"
    end

    n = ceil(length / hash_len)

    {okm, _} =
      Enum.reduce(1..n, {"", ""}, fn i, {acc, prev} ->
        block = :crypto.mac(:hmac, hash, prk, prev <> info <> <<i::8>>)
        {acc <> block, block}
      end)

    binary_part(okm, 0, length)
  end

  @spec derive(binary(), binary(), pos_integer(), keyword()) :: binary()
  def derive(ikm, info, length, opts \\ [])
      when is_binary(ikm) and is_binary(info) and is_integer(length) do
    hash = Keyword.get(opts, :hash, :sha256)
    salt = Keyword.get(opts, :salt, "")
    prk = extract(ikm, salt, hash)
    expand(prk, info, length, hash)
  end

  @spec derive_multiple(binary(), [{String.t(), pos_integer()}], keyword()) :: %{String.t() => binary()}
  def derive_multiple(ikm, derivations, opts \\ [])
      when is_binary(ikm) and is_list(derivations) do
    hash = Keyword.get(opts, :hash, :sha256)
    salt = Keyword.get(opts, :salt, "")
    prk = extract(ikm, salt, hash)

    Map.new(derivations, fn {info, length} ->
      {info, expand(prk, info, length, hash)}
    end)
  end

  @spec generate_salt(pos_integer()) :: binary()
  def generate_salt(byte_length \\ 32) when is_integer(byte_length) and byte_length > 0 do
    :crypto.strong_rand_bytes(byte_length)
  end

  defp hash_length(hash), do: Map.fetch!(@hash_lengths, hash)
end

defmodule Crypto.KeyStore do
  @moduledoc """
  Derives named application keys from a configured master secret using HKDF.
  Keys are cached in the process dictionary for the calling process to avoid
  redundant derivation in hot paths.
  """

  alias Crypto.Hkdf

  @spec get(String.t(), pos_integer()) :: binary()
  def get(purpose, byte_length \\ 32) when is_binary(purpose) and is_integer(byte_length) do
    cache_key = {__MODULE__, purpose, byte_length}

    case Process.get(cache_key) do
      nil ->
        key = derive(purpose, byte_length)
        Process.put(cache_key, key)
        key

      cached ->
        cached
    end
  end

  defp derive(purpose, byte_length) do
    master = Application.fetch_env!(:my_app, :master_secret)
    Hkdf.derive(master, "myapp:#{purpose}", byte_length)
  end
end
```
