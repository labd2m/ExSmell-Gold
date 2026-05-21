```elixir
defmodule UserManagement.ProfileNormalizer do
  @moduledoc """
  Applies a standardized normalization pipeline to user profile field values
  before they are persisted. Normalization rules differ per field and are
  declared in `@field_rules`.

  This module is called by the profile update changeset and the bulk-import
  pipeline. It must be idempotent: normalizing an already-normalized value
  should return the same result.
  """

  @field_rules %{
    first_name:   [:trim, :titlecase, {:max_length, 50}],
    last_name:    [:trim, :titlecase, {:max_length, 50}],
    email:        [:trim, :downcase, {:max_length, 254}],
    username:     [:trim, :downcase, :alphanumeric_only, {:max_length, 30}],
    phone:        [:trim, :digits_only, {:max_length, 15}],
    city:         [:trim, :titlecase, {:max_length, 100}],
    country_code: [:trim, :upcase, {:exact_length, 2}],
    bio:          [:trim, {:max_length, 500}]
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes all known profile fields in `params`.
  Unknown keys are passed through unchanged.
  Returns `{:ok, normalized_params}` or `{:error, [{field, reason}]}`.
  """
  def normalize_profile(params) when is_map(params) do
    {normalized, errors} =
      Enum.reduce(params, {%{}, []}, fn {field, value}, {acc, errs} ->
        atom_field = to_existing_atom_or_nil(field)

        case Map.get(@field_rules, atom_field) do
          nil ->
            {Map.put(acc, field, value), errs}

          rules ->
            case apply_rules(value, rules, field) do
              {:ok, v}        -> {Map.put(acc, field, v), errs}
              {:error, reason} -> {acc, [{field, reason} | errs]}
            end
        end
      end)

    if errors == [] do
      {:ok, normalized}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Normalizes a single field value against a list of rules.
  Returns `{:ok, value}` or `{:error, reason}`.
  """
  def apply_rules(value, rules, field_name \\ :unknown) do
    Enum.reduce_while(rules, {:ok, value}, fn rule, {:ok, v} ->
      case apply_rule(v, rule) do
        {:ok, new_v}     -> {:cont, {:ok, new_v}}
        {:error, reason} -> {:halt, {:error, {field_name, reason}}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Rule application
  # ---------------------------------------------------------------------------

  defp apply_rule(value, :trim),              do: {:ok, normalize_value(value, :trim)}
  defp apply_rule(value, :downcase),          do: {:ok, normalize_value(value, :downcase)}
  defp apply_rule(value, :upcase),            do: {:ok, normalize_value(value, :upcase)}
  defp apply_rule(value, :titlecase),         do: {:ok, normalize_value(value, :titlecase)}
  defp apply_rule(value, :digits_only),       do: {:ok, normalize_value(value, :digits_only)}
  defp apply_rule(value, :alphanumeric_only), do: {:ok, normalize_value(value, :alphanumeric_only)}

  defp apply_rule(value, {:max_length, max}) do
    normalized = normalize_value(value, :trim)
    if String.length(normalized) <= max do
      {:ok, normalized}
    else
      {:error, {:too_long, max}}
    end
  end

  defp apply_rule(value, {:exact_length, len}) do
    normalized = normalize_value(value, :trim)
    if String.length(normalized) == len do
      {:ok, normalized}
    else
      {:error, {:wrong_length, len}}
    end
  end

  defp normalize_value(value, transformation) do
    str = to_string(value)

    case transformation do
      :trim             -> String.trim(str)
      :downcase         -> String.downcase(str)
      :upcase           -> String.upcase(str)
      :titlecase        -> titlecase(str)
      :digits_only      -> String.replace(str, ~r/\D/, "")
      :alphanumeric_only -> String.replace(str, ~r/[^a-zA-Z0-9]/, "")
      _                 -> str
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp titlecase(str) do
    str
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp to_existing_atom_or_nil(key) when is_atom(key), do: key

  defp to_existing_atom_or_nil(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    _ -> nil
  end
end
```
