```elixir
defmodule Mailer.BatchSender do
  @moduledoc """
  Sends a batch of emails concurrently using a `Task.Supervisor`, with
  per-message error isolation and a structured delivery summary.

  Each email is sent in its own supervised task. A failed message does not
  affect the rest of the batch. The summary reports delivery counts and
  collects failure details for operator review.
  """

  alias Mailer.Adapter

  @type recipient :: %{
          to: String.t(),
          subject: String.t(),
          body_html: String.t(),
          body_text: String.t()
        }

  @type delivery_outcome :: :delivered | {:failed, term()}

  @type summary :: %{
          total: non_neg_integer(),
          delivered: non_neg_integer(),
          failed: non_neg_integer(),
          failures: [{recipient(), term()}]
        }

  @default_concurrency 10
  @default_timeout_ms 15_000

  @doc """
  Sends `recipients` in parallel under `task_sup`.

  Returns a structured delivery summary regardless of individual failures.
  Concurrency and per-message timeout are configurable via `opts`.
  """
  @spec send_batch(Supervisor.supervisor(), [recipient()], keyword()) :: summary()
  def send_batch(task_sup, recipients, opts \\ []) when is_list(recipients) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    outcomes =
      recipients
      |> Task.Supervisor.async_stream_nolink(
        task_sup,
        &deliver_one/1,
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(recipients)
      |> Enum.map(&to_outcome/1)

    build_summary(outcomes, recipients)
  end

  defp deliver_one(%{to: to} = recipient) when is_binary(to) do
    Adapter.deliver(recipient)
  end

  defp to_outcome({{:ok, :ok}, _recipient}), do: :delivered
  defp to_outcome({{:ok, {:error, reason}}, recipient}), do: {:failed, recipient, reason}
  defp to_outcome({{:exit, reason}, recipient}), do: {:failed, recipient, {:exit, reason}}

  defp build_summary(outcomes, recipients) do
    {delivered, failures} =
      Enum.reduce(outcomes, {0, []}, fn
        :delivered, {count, errs} -> {count + 1, errs}
        {:failed, recipient, reason}, {count, errs} -> {count, [{recipient, reason} | errs]}
      end)

    %{
      total: length(recipients),
      delivered: delivered,
      failed: length(failures),
      failures: Enum.reverse(failures)
    }
  end
end

defmodule Mailer.TemplateRenderer do
  @moduledoc """
  Renders email body content from named templates and variable bindings.
  """

  @type template_name :: atom()
  @type bindings :: keyword()

  @doc "Renders both HTML and plain-text versions of a named email template."
  @spec render(template_name(), bindings()) ::
          {:ok, %{html: String.t(), text: String.t()}} | {:error, :template_not_found}
  def render(template_name, bindings) when is_atom(template_name) and is_list(bindings) do
    with {:ok, html_template} <- fetch_template(template_name, :html),
         {:ok, text_template} <- fetch_template(template_name, :text) do
      {:ok, %{html: interpolate(html_template, bindings), text: interpolate(text_template, bindings)}}
    end
  end

  defp fetch_template(name, format) do
    path = template_path(name, format)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :template_not_found}
    end
  end

  defp template_path(name, :html), do: "priv/templates/emails/#{name}.html.eex"
  defp template_path(name, :text), do: "priv/templates/emails/#{name}.txt.eex"

  defp interpolate(template, bindings) do
    Enum.reduce(bindings, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end
end
```
