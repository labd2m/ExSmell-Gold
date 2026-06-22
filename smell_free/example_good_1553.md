```elixir
defmodule Notify.Email do
  @moduledoc """
  Composes and dispatches transactional email messages.

  Adapter selection is driven by caller-supplied options, enabling per-call
  provider choice and straightforward test injection.
  """

  alias Notify.Email.{Message, Renderer, Adapter}

  @type recipient :: %{address: String.t(), name: String.t()}

  @type send_opts :: [
          adapter: module(),
          reply_to: String.t(),
          tags: [String.t()]
        ]

  @doc """
  Sends a rendered template email to one or more recipients.

  Returns `{:ok, message_id}` from the delivery adapter, or an error tuple.
  """
  @spec send_template(String.t(), [recipient()], map(), send_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def send_template(template_name, recipients, assigns, opts \\ [])
      when is_binary(template_name) and is_list(recipients) and is_map(assigns) do
    adapter = Keyword.get(opts, :adapter, Adapter.default())

    with {:ok, html_body} <- Renderer.render_html(template_name, assigns),
         {:ok, text_body} <- Renderer.render_text(template_name, assigns),
         {:ok, msg} <- build_message(template_name, recipients, html_body, text_body, opts),
         {:ok, message_id} <- adapter.deliver(msg) do
      {:ok, message_id}
    end
  end

  @doc """
  Sends a plain-text email without template rendering.
  """
  @spec send_plain(String.t(), [recipient()], String.t(), send_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def send_plain(subject, recipients, body, opts \\ [])
      when is_binary(subject) and is_list(recipients) and is_binary(body) do
    adapter = Keyword.get(opts, :adapter, Adapter.default())

    with {:ok, msg} <- build_plain_message(subject, recipients, body, opts),
         {:ok, message_id} <- adapter.deliver(msg) do
      {:ok, message_id}
    end
  end

  # --- private helpers ---

  defp build_message(template, recipients, html, text, opts) do
    subject = template_to_subject(template)

    msg = %Message{
      subject: subject,
      recipients: recipients,
      html_body: html,
      text_body: text,
      reply_to: Keyword.get(opts, :reply_to),
      tags: Keyword.get(opts, :tags, [])
    }

    {:ok, msg}
  end

  defp build_plain_message(subject, recipients, body, opts) do
    msg = %Message{
      subject: subject,
      recipients: recipients,
      text_body: body,
      reply_to: Keyword.get(opts, :reply_to),
      tags: Keyword.get(opts, :tags, [])
    }

    {:ok, msg}
  end

  defp template_to_subject(name) do
    name
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end

defmodule Notify.Email.Message do
  @moduledoc "Immutable value object representing an outbound email message."

  @enforce_keys [:subject, :recipients]
  defstruct subject: nil,
            recipients: [],
            html_body: nil,
            text_body: nil,
            reply_to: nil,
            tags: []

  @type t :: %__MODULE__{
          subject: String.t(),
          recipients: [map()],
          html_body: String.t() | nil,
          text_body: String.t() | nil,
          reply_to: String.t() | nil,
          tags: [String.t()]
        }
end

defmodule Notify.Email.Adapter do
  @moduledoc "Behaviour contract for email delivery adapters."

  @callback deliver(Notify.Email.Message.t()) :: {:ok, String.t()} | {:error, String.t()}

  @spec default() :: module()
  def default, do: Application.get_env(:notify, :email_adapter, Notify.Email.Adapters.Postmark)
end
```
