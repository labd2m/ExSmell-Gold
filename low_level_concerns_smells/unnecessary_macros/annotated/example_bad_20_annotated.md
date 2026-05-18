# Annotated Example 20 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro merge_defaults/2` inside `Notifications.TemplateUtils`
- **Affected function(s):** `merge_defaults/2`
- **Short explanation:** The macro merges two keyword lists at runtime using `Keyword.merge/2`. This is a plain runtime data operation — no compile-time computation is performed or needed. A regular function is the appropriate and simpler choice.

---

```elixir
defmodule Notifications.TemplateUtils do
  @moduledoc """
  Utilities for rendering notification templates with variable substitution
  and default option merging. Used by email, SMS, and push channels.
  """

  @global_defaults [
    sender_name: "Support Team",
    reply_to: "noreply@example.com",
    locale: "en",
    priority: :normal
  ]

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because merge_defaults/2 only calls
  # Keyword.merge/2 on two runtime keyword lists. Keyword merging is a
  # trivially runtime operation; a def function is cleaner and does not
  # impose a `require` dependency on callers.
  defmacro merge_defaults(base, overrides) do
    quote do
      Keyword.merge(unquote(base), unquote(overrides))
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the global default options for notification rendering.
  """
  @spec global_defaults() :: keyword()
  def global_defaults, do: @global_defaults

  @doc """
  Renders a template string by replacing `{{key}}` placeholders with values
  from the provided bindings map.
  """
  @spec render(String.t(), map()) :: String.t()
  def render(template, bindings) when is_binary(template) and is_map(bindings) do
    Enum.reduce(bindings, template, fn {key, value}, acc ->
      placeholder = "{{#{key}}}"
      String.replace(acc, placeholder, to_string(value))
    end)
  end

  @doc """
  Validates that all required placeholders in a template have bindings provided.
  Returns `:ok` or `{:error, list_of_missing_keys}`.
  """
  @spec validate_bindings(String.t(), map()) :: :ok | {:error, list(String.t())}
  def validate_bindings(template, bindings) do
    required =
      Regex.scan(~r/\{\{(\w+)\}\}/, template, capture: :all_but_first)
      |> List.flatten()

    missing = Enum.reject(required, &Map.has_key?(bindings, &1))

    if Enum.empty?(missing), do: :ok, else: {:error, missing}
  end
end

defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Builds and dispatches email notifications using configurable templates
  and per-recipient option overrides.
  """

  require Notifications.TemplateUtils

  alias Notifications.TemplateUtils

  @channel_defaults [
    content_type: "text/html",
    track_opens: true,
    track_clicks: true
  ]

  @doc """
  Builds an email payload for a given template and recipient, merging
  global defaults, channel defaults, and per-call overrides.
  """
  @spec build_payload(map(), map(), keyword()) :: {:ok, map()} | {:error, list(String.t())}
  def build_payload(%{template: template, bindings: bindings}, recipient, overrides \\ []) do
    with :ok <- TemplateUtils.validate_bindings(template, bindings) do
      opts =
        TemplateUtils.global_defaults()
        |> then(&TemplateUtils.merge_defaults(&1, @channel_defaults))
        |> then(&TemplateUtils.merge_defaults(&1, overrides))

      body = TemplateUtils.render(template, bindings)

      payload = %{
        to: recipient.email,
        recipient_name: Map.get(recipient, :name, ""),
        sender_name: Keyword.get(opts, :sender_name),
        reply_to: Keyword.get(opts, :reply_to),
        content_type: Keyword.get(opts, :content_type),
        locale: Keyword.get(opts, :locale),
        priority: Keyword.get(opts, :priority),
        track_opens: Keyword.get(opts, :track_opens),
        track_clicks: Keyword.get(opts, :track_clicks),
        body: body,
        prepared_at: DateTime.utc_now()
      }

      {:ok, payload}
    end
  end

  @doc """
  Dispatches a batch of emails, returning per-recipient results.
  """
  @spec dispatch_batch(list(map()), map(), (map() -> :ok | {:error, any()})) :: list(map())
  def dispatch_batch(recipients, notification, send_fn) do
    Enum.map(recipients, fn recipient ->
      case build_payload(notification, recipient) do
        {:ok, payload} ->
          result = send_fn.(payload)
          %{recipient_id: recipient.id, status: result, dispatched_at: DateTime.utc_now()}

        {:error, missing} ->
          %{recipient_id: recipient.id, status: {:error, {:missing_bindings, missing}}}
      end
    end)
  end

  @doc """
  Returns statistics from a completed dispatch batch.
  """
  @spec batch_stats(list(map())) :: map()
  def batch_stats(results) do
    success_count = Enum.count(results, &(&1.status == :ok))
    failure_count = length(results) - success_count

    %{
      total: length(results),
      succeeded: success_count,
      failed: failure_count,
      success_rate: if(length(results) > 0, do: success_count / length(results), else: 0.0)
    }
  end
end
```
