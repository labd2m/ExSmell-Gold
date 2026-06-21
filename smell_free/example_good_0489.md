```elixir
defmodule Platform.Anonymizer do
  @moduledoc """
  A composable pipeline of pure functions for anonymizing PII fields
  in domain structs and maps before export, logging, or archival.

  Each masker targets a named field and transforms its value in place.
  The pipeline is assembled declaratively from a field spec list, making
  per-schema anonymization rules explicit and independently testable.
  """

  @type field_name :: atom() | String.t()
  @type masker :: (term() -> term())
  @type field_spec :: {field_name(), masker()}
  @type anonymizable :: map() | struct()

  @doc """
  Applies the maskers in `spec` to `data`, returning a new map with all
  specified fields replaced by their anonymized equivalents.
  """
  @spec anonymize(anonymizable(), [field_spec()]) :: map()
  def anonymize(data, spec) when is_list(spec) do
    base = if is_struct(data), do: Map.from_struct(data), else: data

    Enum.reduce(spec, base, fn {field, masker}, acc ->
      Map.update(acc, field, nil, masker)
    end)
  end

  @doc "Anonymizes a list of records, applying the same spec to each."
  @spec anonymize_all([anonymizable()], [field_spec()]) :: [map()]
  def anonymize_all(records, spec) when is_list(records) do
    Enum.map(records, &anonymize(&1, spec))
  end

  @doc "Masks all characters except the last `visible` characters."
  @spec mask_end(pos_integer()) :: masker()
  def mask_end(visible \\ 4) when is_integer(visible) and visible >= 0 do
    fn
      nil -> nil
      value when is_binary(value) ->
        len = String.length(value)
        if len <= visible do
          String.duplicate("*", len)
        else
          String.duplicate("*", len - visible) <> String.slice(value, -visible, visible)
        end
      value -> value
    end
  end

  @doc "Replaces an email address with `u***@domain.tld`."
  @spec mask_email() :: masker()
  def mask_email do
    fn
      nil -> nil
      value when is_binary(value) ->
        case String.split(value, "@", parts: 2) do
          [local, domain] ->
            masked_local = String.first(local) <> String.duplicate("*", max(String.length(local) - 1, 0))
            "#{masked_local}@#{domain}"
          _ -> "***@***.***"
        end
      value -> value
    end
  end

  @doc "Replaces the value entirely with a stable pseudonymous hash."
  @spec pseudonymize(String.t()) :: masker()
  def pseudonymize(salt) when is_binary(salt) do
    fn
      nil -> nil
      value ->
        :crypto.hash(:sha256, "#{salt}:#{value}")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  @doc "Zeroes out a date, keeping only the year."
  @spec mask_date_to_year() :: masker()
  def mask_date_to_year do
    fn
      nil -> nil
      %Date{year: y} -> Date.new!(y, 1, 1)
      _ -> nil
    end
  end

  @doc "Replaces any value with a fixed constant."
  @spec replace_with(term()) :: masker()
  def replace_with(constant), do: fn _ -> constant end

  @doc "Redacts the value completely, replacing it with `nil`."
  @spec redact() :: masker()
  def redact, do: replace_with(nil)

  @doc "Truncates a string to `max_length` characters."
  @spec truncate(pos_integer()) :: masker()
  def truncate(max_length) when is_integer(max_length) and max_length > 0 do
    fn
      nil -> nil
      value when is_binary(value) -> String.slice(value, 0, max_length)
      value -> value
    end
  end
end
```
