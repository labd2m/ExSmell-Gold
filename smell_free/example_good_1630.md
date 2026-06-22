```elixir
defmodule Privacy.DataMasker do
  @moduledoc """
  Applies configurable masking transformations to maps containing PII.
  Each field is masked according to a declared strategy, enabling safe
  logging, export, and display of sensitive data without full redaction.
  """

  @type strategy ::
          :redact
          | :hash
          | {:truncate, pos_integer()}
          | {:partial, non_neg_integer(), non_neg_integer()}
          | :email_safe
          | :phone_safe

  @type mask_spec :: %{field: atom() | String.t(), strategy: strategy()}

  @spec mask(map(), [mask_spec()]) :: map()
  def mask(data, specs) when is_map(data) and is_list(specs) do
    Enum.reduce(specs, data, fn spec, acc ->
      key = spec.field
      value = Map.get(acc, key)

      if is_nil(value) do
        acc
      else
        Map.put(acc, key, apply_strategy(value, spec.strategy))
      end
    end)
  end

  @spec mask_nested(map(), [atom() | String.t()], strategy()) :: map()
  def mask_nested(data, key_path, strategy) when is_list(key_path) do
    update_in(data, key_path, fn value ->
      if is_nil(value), do: value, else: apply_strategy(value, strategy)
    end)
  rescue
    _ -> data
  end

  @spec mask_list([map()], [mask_spec()]) :: [map()]
  def mask_list(items, specs) when is_list(items) do
    Enum.map(items, &mask(&1, specs))
  end

  @spec apply_strategy(term(), strategy()) :: term()
  defp apply_strategy(_value, :redact), do: "[REDACTED]"

  defp apply_strategy(value, :hash) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  defp apply_strategy(value, {:truncate, max_len}) when is_binary(value) do
    String.slice(value, 0, max_len)
  end

  defp apply_strategy(value, {:partial, keep_start, keep_end}) when is_binary(value) do
    len = String.length(value)
    total_keep = keep_start + keep_end

    if len <= total_keep do
      value
    else
      start = String.slice(value, 0, keep_start)
      ending = String.slice(value, len - keep_end, keep_end)
      masked_count = len - total_keep
      "#{start}#{"*" |> String.duplicate(masked_count)}#{ending}"
    end
  end

  defp apply_strategy(value, :email_safe) when is_binary(value) do
    case String.split(value, "@") do
      [local, domain] ->
        masked_local = mask_email_local(local)
        "#{masked_local}@#{domain}"
      _ ->
        "[INVALID_EMAIL]"
    end
  end

  defp apply_strategy(value, :phone_safe) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")

    case String.length(digits) do
      len when len >= 4 ->
        last_four = String.slice(digits, len - 4, 4)
        "#{"*" |> String.duplicate(len - 4)}#{last_four}"
      _ ->
        "****"
    end
  end

  defp apply_strategy(value, _unknown_strategy), do: value

  @spec mask_email_local(String.t()) :: String.t()
  defp mask_email_local(local) when byte_size(local) <= 2, do: String.duplicate("*", String.length(local))

  defp mask_email_local(local) do
    first = String.first(local)
    last = String.last(local)
    middle_len = String.length(local) - 2
    "#{first}#{"*" |> String.duplicate(middle_len)}#{last}"
  end
end
```
