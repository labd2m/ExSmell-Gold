# File: `example_good_964.md`

```elixir
defmodule Observability.BaggagePropagator do
  @moduledoc """
  Manages W3C Baggage context propagation for distributed systems,
  storing arbitrary key-value pairs that travel with a request across
  service boundaries via HTTP headers.

  Baggage is stored in the process dictionary for the duration of a
  request. Helper functions encode and decode the `baggage` HTTP header
  per the W3C Baggage specification.
  """

  @baggage_key {__MODULE__, :baggage}
  @header_name "baggage"
  @max_value_length 4_096

  @type baggage_key :: String.t()
  @type baggage_value :: String.t()
  @type baggage :: %{baggage_key() => baggage_value()}

  @doc """
  Sets a single baggage entry for the current request context.
  """
  @spec set(baggage_key(), baggage_value()) :: :ok
  def set(key, value) when is_binary(key) and is_binary(value) do
    current = get_all()
    Process.put(@baggage_key, Map.put(current, normalize_key(key), value))
    :ok
  end

  @doc """
  Retrieves a single baggage value by key.

  Returns `{:ok, value}` or `{:error, :not_found}`.
  """
  @spec get(baggage_key()) :: {:ok, baggage_value()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    case Map.fetch(get_all(), normalize_key(key)) do
      {:ok, _value} = ok -> ok
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Returns all baggage entries for the current request.
  """
  @spec get_all() :: baggage()
  def get_all do
    Process.get(@baggage_key, %{})
  end

  @doc """
  Removes a single baggage entry from the current request context.
  """
  @spec delete(baggage_key()) :: :ok
  def delete(key) when is_binary(key) do
    Process.put(@baggage_key, Map.delete(get_all(), normalize_key(key)))
    :ok
  end

  @doc """
  Clears all baggage from the current request context.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@baggage_key)
    :ok
  end

  @doc """
  Encodes the current baggage as a W3C-compliant `baggage` header value.

  Returns `nil` when there is no baggage to encode.
  """
  @spec to_header() :: String.t() | nil
  def to_header do
    baggage = get_all()

    if map_size(baggage) == 0 do
      nil
    else
      baggage
      |> Enum.map(fn {k, v} -> "#{URI.encode(k)}=#{URI.encode(v)}" end)
      |> Enum.join(",")
    end
  end

  @doc """
  Parses a W3C `baggage` header string and loads it into the current
  request context, merging with any existing entries.

  Returns `:ok` or `{:error, :malformed_header}` if parsing fails.
  """
  @spec from_header(String.t()) :: :ok | {:error, :malformed_header}
  def from_header(header_value) when is_binary(header_value) do
    parsed =
      header_value
      |> String.split(",")
      |> Enum.reduce_while(%{}, fn entry, acc ->
        case parse_entry(String.trim(entry)) do
          {:ok, key, value} -> {:cont, Map.put(acc, key, value)}
          :error -> {:halt, :error}
        end
      end)

    case parsed do
      :error ->
        {:error, :malformed_header}

      entries ->
        current = get_all()
        Process.put(@baggage_key, Map.merge(current, entries))
        :ok
    end
  end

  @doc """
  Executes `fun/0` with a fresh baggage context, restoring the caller's
  baggage afterwards. Useful for spawning isolated child contexts.
  """
  @spec with_baggage(baggage(), (-> result)) :: result when result: any()
  def with_baggage(initial_baggage, fun)
      when is_map(initial_baggage) and is_function(fun, 0) do
    previous = Process.get(@baggage_key)
    Process.put(@baggage_key, initial_baggage)

    try do
      fun.()
    after
      case previous do
        nil -> Process.delete(@baggage_key)
        prev -> Process.put(@baggage_key, prev)
      end
    end
  end

  @doc """
  Returns the name of the HTTP header used for baggage propagation.
  """
  @spec header_name() :: String.t()
  def header_name, do: @header_name

  defp parse_entry(entry) do
    case String.split(entry, "=", parts: 2) do
      [raw_key, raw_value] when raw_key != "" ->
        key = URI.decode(String.trim(raw_key))
        value = raw_value |> String.trim() |> URI.decode() |> String.slice(0, @max_value_length)
        {:ok, normalize_key(key), value}

      _ ->
        :error
    end
  end

  defp normalize_key(key), do: String.downcase(String.trim(key))
end
```
