```elixir
defmodule Hashvault.Hasher do
  @moduledoc """
  Provides password hashing and verification using Argon2 with
  configurable algorithm parameters. All tuning options are accepted
  at call time via keyword arguments, keeping the library composable
  across multiple use cases in the same application.
  """

  @type hash_opts :: [
          time_cost: pos_integer(),
          memory_cost: pos_integer(),
          parallelism: pos_integer(),
          hash_length: pos_integer()
        ]

  @type verify_result :: :valid | :invalid | {:error, String.t()}

  @default_opts [
    time_cost: 3,
    memory_cost: 65_536,
    parallelism: 2,
    hash_length: 32
  ]

  @spec hash(String.t(), hash_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def hash(plaintext, opts \\ []) when is_binary(plaintext) do
    case validate_plaintext(plaintext) do
      :ok ->
        merged = Keyword.merge(@default_opts, opts)
        perform_hash(plaintext, merged)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec verify(String.t(), String.t()) :: verify_result()
  def verify(plaintext, stored_hash) when is_binary(plaintext) and is_binary(stored_hash) do
    case extract_algorithm(stored_hash) do
      {:ok, :argon2id} -> verify_argon2id(plaintext, stored_hash)
      {:ok, unknown} -> {:error, "unsupported algorithm: #{unknown}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec needs_rehash?(String.t(), hash_opts()) :: boolean()
  def needs_rehash?(stored_hash, desired_opts \\ []) when is_binary(stored_hash) do
    merged = Keyword.merge(@default_opts, desired_opts)

    case parse_hash_params(stored_hash) do
      {:ok, params} ->
        params.time_cost != merged[:time_cost] or
          params.memory_cost != merged[:memory_cost] or
          params.parallelism != merged[:parallelism]

      {:error, _} ->
        true
    end
  end

  @spec validate_plaintext(String.t()) :: :ok | {:error, String.t()}
  defp validate_plaintext(plaintext) do
    cond do
      byte_size(plaintext) < 8 -> {:error, "password must be at least 8 bytes"}
      byte_size(plaintext) > 4096 -> {:error, "password exceeds maximum allowed length"}
      true -> :ok
    end
  end

  @spec perform_hash(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp perform_hash(plaintext, opts) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)

    try do
      hash =
        Argon2.Base.hash_password(plaintext, salt,
          t_cost: opts[:time_cost],
          m_cost: opts[:memory_cost],
          parallelism: opts[:parallelism],
          hashlen: opts[:hash_length],
          argon2_type: 2
        )

      {:ok, hash}
    rescue
      e -> {:error, "hashing failed: #{Exception.message(e)}"}
    end
  end

  @spec verify_argon2id(String.t(), String.t()) :: verify_result()
  defp verify_argon2id(plaintext, stored_hash) do
    if Argon2.verify_pass(plaintext, stored_hash) do
      :valid
    else
      :invalid
    end
  rescue
    _ -> :invalid
  end

  @spec extract_algorithm(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp extract_algorithm("$argon2id$" <> _), do: {:ok, :argon2id}
  defp extract_algorithm("$argon2i$" <> _), do: {:ok, :argon2i}
  defp extract_algorithm("$argon2d$" <> _), do: {:ok, :argon2d}
  defp extract_algorithm(_), do: {:error, "unrecognized hash format"}

  @spec parse_hash_params(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_hash_params(stored_hash) do
    with {:ok, _algo} <- extract_algorithm(stored_hash),
         [_, params_str | _] <- String.split(stored_hash, "$", trim: false),
         pairs when pairs != [] <- String.split(params_str, ",") do
      params =
        Map.new(pairs, fn pair ->
          [k, v] = String.split(pair, "=")
          {String.to_existing_atom(k), String.to_integer(v)}
        end)

      {:ok, params}
    else
      _ -> {:error, "could not parse hash parameters"}
    end
  rescue
    _ -> {:error, "could not parse hash parameters"}
  end
end
```
