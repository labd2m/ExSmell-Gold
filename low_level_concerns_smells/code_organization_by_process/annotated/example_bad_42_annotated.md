# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `TemplateRenderer` module — entire GenServer structure |
| **Affected function(s)** | `render/3`, `render_subject/3`, `render_all/3`, `preview/3` |
| **Short explanation** | Template rendering is a pure string interpolation operation over a template string and a bindings map. No state is stored or modified between calls, no external resource is locked, and no concurrency primitive is required. Routing all notification rendering through a single GenServer prevents parallel rendering of independent messages. |

```elixir
defmodule Notifications.TemplateRenderer do
  use GenServer

  @moduledoc """
  Renders notification templates (email, SMS, push) by interpolating
  variable bindings into template strings. Used by the messaging
  pipeline before dispatching notifications to users.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because template rendering is purely
  # functional — it takes a template string and a bindings map, performs
  # string substitution, and returns the result. No state is shared between
  # calls and nothing about this work requires a process. When the notification
  # service sends thousands of messages concurrently, all rendering is
  # serialised through this single process mailbox unnecessarily.

  @templates %{
    welcome_email: %{
      subject: "Welcome to {{app_name}}, {{first_name}}!",
      body: """
      Hi {{first_name}},

      Welcome to {{app_name}}! Your account has been created successfully.
      Your username is {{username}}.

      Get started at: {{app_url}}/dashboard

      Regards,
      The {{app_name}} Team
      """
    },
    password_reset: %{
      subject: "Password reset request for {{app_name}}",
      body: """
      Hi {{first_name}},

      We received a request to reset your password.
      Click the link below (expires in {{expiry_minutes}} minutes):

      {{reset_url}}

      If you did not request this, please ignore this email.
      """
    },
    order_shipped: %{
      subject: "Your order #{{order_number}} has shipped!",
      body: """
      Hi {{first_name}},

      Great news — your order #{{order_number}} is on its way.
      Estimated delivery: {{estimated_delivery}}
      Tracking number: {{tracking_number}}

      Track your shipment: {{tracking_url}}
      """
    },
    invoice_ready: %{
      subject: "Invoice #{{invoice_number}} is ready",
      body: """
      Hi {{first_name}},

      Invoice #{{invoice_number}} for {{amount}} is now available.
      Due date: {{due_date}}

      View invoice: {{invoice_url}}
      """
    }
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Renders the body of `template_name` with the given `bindings` map.
  Returns `{:ok, rendered_string}` or `{:error, reason}`.
  """
  def render(pid, template_name, bindings) do
    GenServer.call(pid, {:render, template_name, bindings})
  end

  @doc "Renders only the subject line for `template_name`."
  def render_subject(pid, template_name, bindings) do
    GenServer.call(pid, {:render_subject, template_name, bindings})
  end

  @doc "Renders both subject and body. Returns `{:ok, %{subject:, body:}}`."
  def render_all(pid, template_name, bindings) do
    GenServer.call(pid, {:render_all, template_name, bindings})
  end

  @doc "Returns the raw template without interpolation for preview/editing."
  def preview(pid, template_name) do
    GenServer.call(pid, {:preview, template_name})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:render, template_name, bindings}, _from, state) do
    result =
      case Map.get(@templates, template_name) do
        nil      -> {:error, :unknown_template}
        %{body: body} -> {:ok, interpolate(body, bindings)}
      end

    {:reply, result, state}
  end

  def handle_call({:render_subject, template_name, bindings}, _from, state) do
    result =
      case Map.get(@templates, template_name) do
        nil               -> {:error, :unknown_template}
        %{subject: subj}  -> {:ok, interpolate(subj, bindings)}
      end

    {:reply, result, state}
  end

  def handle_call({:render_all, template_name, bindings}, _from, state) do
    result =
      case Map.get(@templates, template_name) do
        nil ->
          {:error, :unknown_template}

        %{subject: subj, body: body} ->
          {:ok, %{
            subject: interpolate(subj, bindings),
            body:    interpolate(body, bindings)
          }}
      end

    {:reply, result, state}
  end

  def handle_call({:preview, template_name}, _from, state) do
    result =
      case Map.get(@templates, template_name) do
        nil      -> {:error, :unknown_template}
        template -> {:ok, template}
      end

    {:reply, result, state}
  end

  ## Private helpers

  defp interpolate(template, bindings) do
    Enum.reduce(bindings, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  # VALIDATION: SMELL END
end
```
