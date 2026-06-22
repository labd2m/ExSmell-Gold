```elixir
defmodule Ecto.ChangesetHelpers do
  @moduledoc """
  A collection of reusable, composable changeset validation and
  transformation functions that extend the standard Ecto.Changeset API
  for common domain validation patterns.
  """

  import Ecto.Changeset

  @type changeset :: Ecto.Changeset.t()

  @spec validate_url(changeset(), atom()) :: changeset()
  def validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      uri = URI.parse(value)

      if is_binary(uri.scheme) and uri.scheme in ["http", "https"] and is_binary(uri.host) do
        []
      else
        [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end

  @spec validate_phone(changeset(), atom()) :: changeset()
  def validate_phone(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      cleaned = String.replace(value, ~r/[\s\-\(\)]/, "")

      if Regex.match?(~r/^\+?[1-9]\d{6,14}$/, cleaned) do
        []
      else
        [{field, "must be a valid phone number"}]
      end
    end)
  end

  @spec validate_future_date(changeset(), atom()) :: changeset()
  def validate_future_date(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      today = Date.utc_today()

      if Date.compare(value, today) == :gt do
        []
      else
        [{field, "must be a future date"}]
      end
    end)
  end

  @spec validate_slug(changeset(), atom()) :: changeset()
  def validate_slug(changeset, field) do
    changeset
    |> validate_format(field, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_length(field, min: 2, max: 64)
  end

  @spec validate_list_length(changeset(), atom(), keyword()) :: changeset()
  def validate_list_length(changeset, field, opts) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max)

    validate_change(changeset, field, fn _, value when is_list(value) ->
      count = length(value)

      cond do
        count < min -> [{field, "must have at least #{min} items"}]
        not is_nil(max) and count > max -> [{field, "must have at most #{max} items"}]
        true -> []
      end
    end)
  end

  @spec normalise_email(changeset(), atom()) :: changeset()
  def normalise_email(changeset, field) do
    update_change(changeset, field, fn value ->
      value |> String.trim() |> String.downcase()
    end)
  end

  @spec put_if_nil(changeset(), atom(), term()) :: changeset()
  def put_if_nil(changeset, field, default_value) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default_value)
      _ -> changeset
    end
  end

  @spec validate_mutually_exclusive(changeset(), atom(), atom()) :: changeset()
  def validate_mutually_exclusive(changeset, field_a, field_b) do
    a = get_field(changeset, field_a)
    b = get_field(changeset, field_b)

    if not is_nil(a) and not is_nil(b) do
      add_error(changeset, field_a, "cannot be set together with #{field_b}")
    else
      changeset
    end
  end

  @spec validate_at_least_one(changeset(), [atom()]) :: changeset()
  def validate_at_least_one(changeset, fields) when is_list(fields) do
    any_present = Enum.any?(fields, fn f -> not is_nil(get_field(changeset, f)) end)

    if any_present do
      changeset
    else
      field_list = Enum.join(fields, ", ")
      add_error(changeset, hd(fields), "at least one of #{field_list} must be present")
    end
  end
end
```
