```elixir
# ── file: lib/mailer/composer.ex ────────────────────────────────────────────


defmodule Mailer.Composer do
  @moduledoc """
  Constructs email messages from structured data or templates.
  Defined in `lib/mailer/composer.ex`.
  """

  alias Mailer.{TemplateRenderer, AttachmentStore, AddressValidator}

  @default_from {"My App", "no-reply@example.com"}
  @max_attachment_mb 10

  @type email :: %{
    from: {String.t(), String.t()},
    to: [{String.t(), String.t()}],
    reply_to: String.t() | nil,
    subject: String.t(),
    text_body: String.t() | nil,
    html_body: String.t() | nil,
    attachments: [map()],
    headers: map()
  }

  @doc "Build a plain email struct from raw fields."
  @spec build(String.t() | [String.t()], String.t(), map()) ::
          {:ok, email()} | {:error, String.t()}
  def build(to, subject, opts \\ %{}) do
    recipients = List.wrap(to) |> Enum.map(&normalise_recipient/1)

    with :ok <- validate_recipients(recipients) do
      email = %{
        from: Map.get(opts, :from, @default_from),
        to: recipients,
        reply_to: Map.get(opts, :reply_to),
        subject: subject,
        text_body: Map.get(opts, :text_body),
        html_body: Map.get(opts, :html_body),
        attachments: [],
        headers: Map.get(opts, :headers, %{})
      }

      {:ok, email}
    end
  end

  @doc "Compose an email by rendering a named template with assigns."
  @spec from_template(String.t() | [String.t()], String.t(), map()) ::
          {:ok, email()} | {:error, String.t()}
  def from_template(to, template_name, assigns) do
    with {:ok, rendered} <- TemplateRenderer.render(template_name, assigns),
         {:ok, email} <- build(to, rendered.subject, %{html_body: rendered.html, text_body: rendered.text}) do
      {:ok, email}
    end
  end

  @doc "Attach a file to an email from a storage key or local path."
  @spec add_attachment(email(), map()) :: {:ok, email()} | {:error, String.t()}
  def add_attachment(email, %{key: key, filename: filename, content_type: ct}) do
    with {:ok, content} <- AttachmentStore.fetch(key),
         :ok <- check_attachment_size(content) do
      attachment = %{
        filename: filename,
        content_type: ct,
        content: content,
        disposition: :attachment
      }

      {:ok, %{email | attachments: [attachment | email.attachments]}}
    end
  end

  def add_attachment(_email, _attachment_spec) do
    {:error, "Attachment spec must include :key, :filename, and :content_type"}
  end

  @doc "Set a reply-to address on an existing email struct."
  @spec set_reply_to(email(), String.t()) :: {:ok, email()} | {:error, String.t()}
  def set_reply_to(email, address) do
    case AddressValidator.validate(address) do
      :ok -> {:ok, %{email | reply_to: address}}
      {:error, reason} -> {:error, "Invalid reply-to address: #{reason}"}
    end
  end

  @doc "Render the HTML body of an email into a preview-safe string."
  @spec render_html(email()) :: {:ok, String.t()} | {:error, String.t()}
  def render_html(%{html_body: nil}) do
    {:error, "Email has no HTML body"}
  end

  def render_html(%{html_body: html}) do
    sanitised =
      html
      |> String.replace(~r/<script[^>]*>.*?<\/script>/si, "")
      |> String.replace(~r/on\w+="[^"]*"/i, "")

    {:ok, sanitised}
  end

  defp normalise_recipient(addr) when is_binary(addr), do: {"", addr}
  defp normalise_recipient({name, addr}), do: {name, addr}

  defp validate_recipients([]), do: {:error, "At least one recipient required"}

  defp validate_recipients(recipients) do
    invalid = Enum.reject(recipients, fn {_, addr} -> String.contains?(addr, "@") end)
    if invalid == [], do: :ok, else: {:error, "Invalid recipient addresses: #{inspect(invalid)}"}
  end

  defp check_attachment_size(content) when byte_size(content) > @max_attachment_mb * 1_048_576 do
    {:error, "Attachment exceeds max size of #{@max_attachment_mb} MB"}
  end

  defp check_attachment_size(_content), do: :ok
end


# ── file: lib/mailer/composer_preview.ex ─────────────────────────────────────────────────────


defmodule Mailer.Composer do
  @moduledoc """
  Email preview rendering utilities for in-app email preview feature.
  identically to the core composer module.
  """

  alias Mailer.PreviewStore

  @doc "Generate a web-accessible preview URL for a composed email."
  @spec preview_url(map()) :: {:ok, String.t()} | {:error, String.t()}
  def preview_url(email) do
    preview_id = generate_id()

    case PreviewStore.save(preview_id, email, ttl: 3600) do
      :ok ->
        base = Application.get_env(:my_app, :preview_base_url, "https://preview.example.com")
        {:ok, "#{base}/email-preview/#{preview_id}"}

      {:error, reason} ->
        {:error, "Failed to save preview: #{inspect(reason)}"}
    end
  end

  @doc "Retrieve a previously stored email preview by ID."
  @spec fetch_preview(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_preview(preview_id) do
    case PreviewStore.get(preview_id) do
      {:ok, email} -> {:ok, email}
      :not_found -> {:error, "Preview not found or expired: #{preview_id}"}
    end
  end

  @doc "Return a text-only version of an email for preview purposes."
  @spec text_preview(map(), pos_integer()) :: String.t()
  def text_preview(%{text_body: text}, max_chars \\ 200) when is_binary(text) do
    text
    |> String.slice(0, max_chars)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> then(&if String.length(&1) == max_chars, do: &1 <> "…", else: &1)
  end

  def text_preview(%{html_body: html}, max_chars) when is_binary(html) do
    text =
      html
      |> String.replace(~r/<[^>]+>/, " ")
      |> String.replace(~r/&\w+;/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    text_preview(%{text_body: text}, max_chars)
  end

  def text_preview(_email, _max_chars), do: "(No preview available)"

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

```
