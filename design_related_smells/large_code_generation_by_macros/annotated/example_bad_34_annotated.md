# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro auditable/2` inside `MyApp.Audit.EventDSL`
- **Affected function(s):** `auditable/2` macro
- **Short explanation:** Every call to `auditable/2` expands a large `quote` block that validates the action atom, severity level, actor field, target field, retention period, and mask-fields list — as well as performing deduplication and registering the event struct — entirely inline. Delegating this work to a plain function would produce the same result with far less repeated compiled code.

---

```elixir
defmodule MyApp.Audit.EventDSL do
  @moduledoc """
  DSL for declaring auditable event types within an audit configuration module.

  Example:

      defmodule MyApp.Audit.Events do
        use MyApp.Audit.EventDSL

        auditable :user_login,
          severity:   :info,
          actor:      :user_id,
          target:     :session_id,
          retention:  365,
          description: "User authenticated successfully"

        auditable :payment_captured,
          severity:    :warning,
          actor:       :user_id,
          target:      :payment_id,
          retention:   2555,
          mask_fields: [:card_number, :cvv],
          description: "Payment charge captured"

        auditable :admin_impersonation,
          severity:   :critical,
          actor:      :admin_id,
          target:     :impersonated_user_id,
          retention:  3650,
          description: "Admin assumed user identity"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Audit.EventDSL, only: [auditable: 2]
      Module.register_attribute(__MODULE__, :audit_events, accumulate: true)
      @before_compile MyApp.Audit.EventDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def audit_events, do: @audit_events

      def event_spec(action) do
        Enum.find(@audit_events, fn e -> e.action == action end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to auditable/2 expands this
  # VALIDATION: entire block inline at the call site: action atom check, severity
  # VALIDATION: enumeration check, actor field atom check, target field atom
  # VALIDATION: check, retention positive-integer check, mask_fields list-of-atoms
  # VALIDATION: check, description string check, deduplication guard, and event
  # VALIDATION: struct construction. An audit module defining many event types
  # VALIDATION: compiles all of this validation code multiple times rather than
  # VALIDATION: once inside a shared helper function.
  defmacro auditable(action, opts) do
    quote do
      action = unquote(action)
      opts   = unquote(opts)

      unless is_atom(action) do
        raise ArgumentError,
              "auditable/2: action must be an atom, got #{inspect(action)}"
      end

      valid_severities = [:debug, :info, :warning, :error, :critical]
      severity = Keyword.get(opts, :severity, :info)

      unless severity in valid_severities do
        raise ArgumentError,
              "auditable/2: :severity must be one of #{inspect(valid_severities)}, " <>
                "got #{inspect(severity)}"
      end

      actor = Keyword.get(opts, :actor)

      unless is_atom(actor) do
        raise ArgumentError,
              "auditable/2: :actor must be an atom field name, got #{inspect(actor)}"
      end

      target = Keyword.get(opts, :target)

      unless is_nil(target) or is_atom(target) do
        raise ArgumentError,
              "auditable/2: :target must be an atom field name or nil, got #{inspect(target)}"
      end

      retention = Keyword.get(opts, :retention, 90)

      unless is_integer(retention) and retention > 0 do
        raise ArgumentError,
              "auditable/2: :retention must be a positive integer (days), " <>
                "got #{inspect(retention)}"
      end

      mask_fields = Keyword.get(opts, :mask_fields, [])

      unless is_list(mask_fields) and Enum.all?(mask_fields, &is_atom/1) do
        raise ArgumentError,
              "auditable/2: :mask_fields must be a list of atom field names, " <>
                "got #{inspect(mask_fields)}"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "auditable/2: :description must be a string, got #{inspect(description)}"
      end

      existing = Module.get_attribute(__MODULE__, :audit_events)

      if Enum.any?(existing, fn e -> e.action == action end) do
        raise ArgumentError,
              "auditable/2: duplicate audit event #{inspect(action)} in #{inspect(__MODULE__)}"
      end

      event = %{
        action:      action,
        severity:    severity,
        actor:       actor,
        target:      target,
        retention:   retention,
        mask_fields: mask_fields,
        description: description
      }

      @audit_events event
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Builds an audit log entry from a registered event spec and the given context
  map, masking any sensitive fields before persisting.
  """
  @spec build_entry(module(), atom(), map()) :: {:ok, map()} | {:error, String.t()}
  def build_entry(events_module, action, context) do
    case events_module.event_spec(action) do
      nil ->
        {:error, "Unknown audit event: #{inspect(action)}"}

      spec ->
        masked_context =
          Enum.reduce(spec.mask_fields, context, fn field, acc ->
            Map.update(acc, field, nil, fn _ -> "[REDACTED]" end)
          end)

        entry = %{
          action:     action,
          severity:   spec.severity,
          actor:      Map.get(context, spec.actor),
          target:     Map.get(context, spec.target),
          payload:    masked_context,
          recorded_at: DateTime.utc_now()
        }

        {:ok, entry}
    end
  end
end
```
