```elixir
defmodule Privacy.Anonymiser do
  @moduledoc """
  Produces anonymised copies of domain structs for use in analytics,
  exports, and non-production environments. Each field is transformed
  by a declared anonymisation rule, with referential integrity preserved
  through consistent pseudonymisation of ID fields.
  """

  @type rule ::
          :drop
          | :nullify
          | :fake_name
          | :fake_email
          | :fake_phone
          | :fake_ip
          | {:fixed, term()}
          | {:pseudonymise, String.t()}

  @type field_rule :: {atom(), rule()}

  @type schema :: [field_rule()]

  @spec anonymise(map(), schema()) :: map()
  def anonymise(record, schema) when is_map(record) and is_list(schema) do
    schema_map = Map.new(schema)

    record
    |> Map.reject(fn {key, _} -> Map.get(schema_map, key) == :drop end)
    |> Map.new(fn {key, value} ->
      rule = Map.get(schema_map, key, :keep)
      {key, transform(value, rule)}
    end)
  end

  @spec anonymise_list([map()], schema()) :: [map()]
  def anonymise_list(records, schema) when is_list(records) do
    Enum.map(records, &anonymise(&1, schema))
  end

  @spec anonymise_consistent([map()], schema()) :: [map()]
  def anonymise_consistent(records, schema) when is_list(records) do
    id_fields =
      schema
      |> Enum.filter(fn {_field, rule} -> match?({:pseudonymise, _}, rule) end)
      |> Enum.map(fn {field, _} -> field end)

    seed_map =
      records
      |> Enum.flat_map(fn r -> Enum.map(id_fields, &{&1, Map.get(r, &1)}) end)
      |> Enum.uniq()
      |> Map.new(fn {field, value} -> {{field, value}, pseudonymise(value, to_string(field))} end)

    Enum.map(records, fn record ->
      schema_with_resolved =
        Enum.map(schema, fn
          {field, {:pseudonymise, namespace}} ->
            original = Map.get(record, field)
            mapped = Map.get(seed_map, {field, original}, pseudonymise(original, namespace))
            {field, {:fixed, mapped}}

          other ->
            other
        end)

      anonymise(record, schema_with_resolved)
    end)
  end

  @spec transform(term(), rule()) :: term()
  defp transform(_value, :nullify), do: nil
  defp transform(_value, :drop), do: nil
  defp transform(_value, :fake_name), do: random_name()
  defp transform(_value, :fake_email), do: random_email()
  defp transform(_value, :fake_phone), do: random_phone()
  defp transform(_value, :fake_ip), do: random_ip()
  defp transform(_value, {:fixed, replacement}), do: replacement
  defp transform(value, {:pseudonymise, namespace}), do: pseudonymise(value, namespace)
  defp transform(value, :keep), do: value
  defp transform(value, _unknown), do: value

  @spec pseudonymise(term(), String.t()) :: String.t()
  defp pseudonymise(value, namespace) do
    input = "#{namespace}:#{value}"
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  @spec random_name() :: String.t()
  defp random_name do
    first = Enum.random(~w[Alex Jordan Sam Morgan Casey Riley])
    last = Enum.random(~w[Smith Jones Brown Wilson Taylor Davies])
    "#{first} #{last}"
  end

  @spec random_email() :: String.t()
  defp random_email do
    local = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    "#{local}@example.com"
  end

  @spec random_phone() :: String.t()
  defp random_phone do
    suffix = :rand.uniform(9_000_000) + 1_000_000
    "+1555#{suffix}"
  end

  @spec random_ip() :: String.t()
  defp random_ip do
    "192.0.2.#{:rand.uniform(254)}"
  end
end
```
