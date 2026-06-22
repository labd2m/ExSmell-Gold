```elixir
defmodule Mailer.Template do
  @moduledoc """
  A resolved email template containing the final subject and body strings.
  Templates are produced by `Mailer.Renderer` from a named template and
  a map of bindings. The struct is immutable once built.
  """

  @enforce_keys [:name, :subject, :html_body, :text_body]
  defstruct [:name, :subject, :html_body, :text_body]

  @type t :: %__MODULE__{
          name: atom(),
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t()
        }
end

defmodule Mailer.Renderer do
  @moduledoc """
  Compiles EEx-based email templates from the priv/templates/email directory.
  Each named template must have a corresponding subject, html, and txt file.
  Variable interpolation is performed at render time against caller-supplied bindings.
  """

  alias Mailer.Template

  @templates_root "priv/templates/email"

  @type bindings :: %{atom() => term()}
  @type render_error :: {:error, {:missing_template, atom()} | {:render_failed, atom(), term()}}

  @spec render(atom(), bindings()) :: {:ok, Template.t()} | render_error()
  def render(name, bindings) when is_atom(name) and is_map(bindings) do
    with {:ok, subject_tpl} <- load_template(name, :subject),
         {:ok, html_tpl} <- load_template(name, :html),
         {:ok, text_tpl} <- load_template(name, :text),
         {:ok, subject} <- evaluate(name, subject_tpl, bindings),
         {:ok, html_body} <- evaluate(name, html_tpl, bindings),
         {:ok, text_body} <- evaluate(name, text_tpl, bindings) do
      {:ok,
       %Template{
         name: name,
         subject: String.trim(subject),
         html_body: html_body,
         text_body: text_body
       }}
    end
  end

  @spec available_templates() :: list(atom())
  def available_templates do
    case File.ls(@templates_root) do
      {:ok, dirs} ->
        dirs
        |> Enum.filter(&File.dir?(Path.join(@templates_root, &1)))
        |> Enum.map(&String.to_existing_atom/1)
      {:error, _} -> []
    end
  end

  defp load_template(name, part) do
    path = template_path(name, part)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, {:missing_template, name}}
    end
  end

  defp evaluate(name, template_string, bindings) do
    assigns = Map.to_list(bindings)

    result =
      try do
        {:ok, EEx.eval_string(template_string, assigns: assigns)}
      rescue
        err -> {:error, {:render_failed, name, err}}
      end

    result
  end

  defp template_path(name, :subject), do: Path.join([@templates_root, to_string(name), "subject.eex"])
  defp template_path(name, :html), do: Path.join([@templates_root, to_string(name), "body.html.eex"])
  defp template_path(name, :text), do: Path.join([@templates_root, to_string(name), "body.txt.eex"])
end

defmodule Mailer.Sender do
  @moduledoc """
  Sends a resolved `Mailer.Template` to one or more recipients.
  Adapters are passed as runtime options so the caller controls the
  delivery mechanism without modifying this module.
  """

  alias Mailer.Template

  @type recipient :: %{email: String.t(), name: String.t() | nil}
  @type send_result :: {:ok, String.t()} | {:error, term()}

  @spec send_template(Template.t(), recipient(), keyword()) :: send_result()
  def send_template(%Template{} = template, %{email: email} = recipient, opts \\ [])
      when is_binary(email) do
    adapter = Keyword.get(opts, :adapter, Mailer.Adapters.SMTP)

    message = build_message(template, recipient)
    adapter.deliver(message, opts)
  end

  defp build_message(%Template{} = tpl, recipient) do
    %{
      to: format_recipient(recipient),
      subject: tpl.subject,
      html_body: tpl.html_body,
      text_body: tpl.text_body
    }
  end

  defp format_recipient(%{email: email, name: name}) when is_binary(name) do
    ~s("#{name}" <#{email}>)
  end

  defp format_recipient(%{email: email}), do: email
end
```
