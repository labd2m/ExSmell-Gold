# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Privacy.PiiMasker` module, `mask_fields/2` macro |
| **Affected function(s)** | `mask_fields/2` |
| **Short explanation** | `mask_fields/2` iterates over a runtime list of field keys and replaces their values in a runtime map. Both arguments are runtime values; the operation is a simple `Enum.reduce` on a map. A regular function is the correct abstraction; the macro adds `quote/unquote` overhead and a mandatory `require` at every call site for no gain. |

```elixir
defmodule Privacy.PiiMasker do
  @moduledoc """
  Masks personally identifiable information before data is written to
  logs, exported to analytics pipelines, or returned in admin API responses.
  Complies with the company's data-minimisation policy under LGPD/GDPR.
  """

  @masked_value "[MASKED]"

  @default_pii_fields ~w(
    email
    phone
    cpf
    ssn
    date_of_birth
    full_name
    address
    ip_address
    credit_card_number
  )a

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `mask_fields/2` receives a map and a
  # list of field keys — both runtime values — and calls `Enum.reduce/3` to
  # replace each field with a masked string. There is no AST transformation
  # involved at any stage. A `def` function would be shorter, directly
  # testable, and callable without a `require` directive, making this macro
  # definition entirely unnecessary.
  defmacro mask_fields(data, fields) do
    quote do
      Enum.reduce(unquote(fields), unquote(data), fn field, acc ->
        if Map.has_key?(acc, field) do
          Map.put(acc, field, unquote(@masked_value))
        else
          acc
        end
      end)
    end
  end
  # VALIDATION: SMELL END

  def mask_user(user, level \\ :standard) do
    require Privacy.PiiMasker

    fields_to_mask =
      case level do
        :minimal  -> [:email, :phone]
        :standard -> @default_pii_fields
        :full     -> Map.keys(user)
      end

    Privacy.PiiMasker.mask_fields(user, fields_to_mask)
  end

  def mask_for_log(record) do
    require Privacy.PiiMasker
    Privacy.PiiMasker.mask_fields(record, @default_pii_fields)
  end

  def mask_for_export(records, extra_fields \\ []) do
    require Privacy.PiiMasker

    fields = @default_pii_fields ++ extra_fields

    Enum.map(records, fn record ->
      Privacy.PiiMasker.mask_fields(record, fields)
    end)
  end

  def safe_inspect(record) do
    require Privacy.PiiMasker

    masked = Privacy.PiiMasker.mask_fields(record, @default_pii_fields)
    inspect(masked)
  end

  def audit_diff(before_record, after_record) do
    require Privacy.PiiMasker

    %{
      before: Privacy.PiiMasker.mask_fields(before_record, @default_pii_fields),
      after:  Privacy.PiiMasker.mask_fields(after_record,  @default_pii_fields),
      changed_keys:
        Map.keys(before_record)
        |> Enum.filter(fn k -> Map.get(before_record, k) != Map.get(after_record, k) end)
    }
  end

  def redact_nested(data, path) when is_list(path) do
    case path do
      [key] ->
        require Privacy.PiiMasker
        Privacy.PiiMasker.mask_fields(data, [key])

      [head | tail] ->
        case Map.get(data, head) do
          nested when is_map(nested) ->
            Map.put(data, head, redact_nested(nested, tail))

          _ ->
            data
        end
    end
  end

  def default_pii_fields, do: @default_pii_fields
end
```
