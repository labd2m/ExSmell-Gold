```elixir
defmodule Privacy.Masking do
  @moduledoc """
  Provides declarative field-level masking for Elixir structs and maps.
  Modules that hold sensitive data implement the `Privacy.Maskable` protocol
  so that any diagnostic or logging call site can safely render them without
  risk of leaking PII. Each field declares its own masking strategy, keeping
  the policy co-located with the data definition rather than scattered across
  call sites.
  """

  @type strategy ::
          :redact
          | :email
          | :phone
          | :partial
          | {:partial, keep_first: non_neg_integer(), keep_last: non_neg_integer()}
          | :hash

  @doc """
  Applies the masking strategy `strategy` to `value`, returning the masked string.
  """
  @spec mask(term(), strategy()) :: binary()
  def mask(nil, _strategy), do: "[nil]"

  def mask(value, :redact) when is_binary(value), do: "[REDACTED]"

  def mask(value, :email) when is_binary(value) do
    case String.split(value, "@") do
      [local, domain] ->
        masked_local = mask_partial(local, 2, 0)
        "#{masked_local}@#{domain}"

      _ ->
        "[INVALID_EMAIL]"
    end
  end

  def mask(value, :phone) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")
    len = String.length(digits)

    if len >= 4 do
      visible = String.slice(digits, -4, 4)
      String.duplicate("*", len - 4) <> visible
    else
      String.duplicate("*", len)
    end
  end

  def mask(value, :partial) when is_binary(value) do
    mask_partial(value, 2, 2)
  end

  def mask(value, {:partial, keep_first: first, keep_last: last})
      when is_binary(value) and is_integer(first) and is_integer(last) do
    mask_partial(value, first, last)
  end

  def mask(value, :hash) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
    |> then(&"[sha256:#{&1}...]")
  end

  def mask(value, strategy) when not is_binary(value) do
    value |> to_string() |> mask(strategy)
  end

  # ---------------------------------------------------------------------------
  # Struct/map helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns a copy of `map` with the specified `fields` masked using the
  given strategy. Accepts a single strategy applied to all fields, or a
  keyword list of `{field, strategy}` pairs for per-field control.
  """
  @spec mask_fields(map(), [atom()] | [{atom(), strategy()}], strategy()) :: map()
  def mask_fields(map, fields, default_strategy \\ :redact) when is_map(map) do
    Enum.reduce(fields, map, fn
      {field, strategy}, acc ->
        Map.update(acc, field, "[nil]", &mask(&1, strategy))

      field, acc when is_atom(field) ->
        Map.update(acc, field, "[nil]", &mask(&1, default_strategy))
    end)
  end

  @doc """
  Returns a safe inspect representation of any struct that implements
  `Privacy.Maskable`, suitable for use in log lines and error reports.
  """
  @spec safe_inspect(Privacy.Maskable.t()) :: binary()
  def safe_inspect(maskable) do
    maskable
    |> Privacy.Maskable.mask()
    |> inspect()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp mask_partial(value, keep_first, keep_last) do
    len = String.length(value)
    visible_count = keep_first + keep_last

    if len <= visible_count do
      String.duplicate("*", len)
    else
      prefix = String.slice(value, 0, keep_first)
      suffix = if keep_last > 0, do: String.slice(value, -keep_last, keep_last), else: ""
      middle_count = len - keep_first - keep_last
      prefix <> String.duplicate("*", middle_count) <> suffix
    end
  end
end

defprotocol Privacy.Maskable do
  @moduledoc """
  Protocol for structs that contain sensitive fields. Implementations return
  a copy of the struct with PII masked, safe for logging and diagnostics.
  """

  @doc "Returns a copy of the struct with all sensitive fields masked."
  @spec mask(t()) :: map()
  def mask(struct)
end

defmodule MyApp.Accounts.User do
  @moduledoc false
  defstruct [:id, :name, :email, :phone, :tax_id, :role, :inserted_at]

  defimpl Privacy.Maskable do
    alias Privacy.Masking

    def mask(user) do
      %{
        id: user.id,
        name: user.name,
        email: Masking.mask(user.email, :email),
        phone: Masking.mask(user.phone, :phone),
        tax_id: Masking.mask(user.tax_id, :redact),
        role: user.role,
        inserted_at: user.inserted_at
      }
    end
  end
end
```
