# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro email_template/2` inside `MyApp.Mailer.TemplateDSL`
- **Affected function(s):** `email_template/2` macro
- **Short explanation:** Every call to `email_template/2` expands a large `quote` block inlining template-name validation, subject validation, required-variables list checks, layout module checks, locale list validation, deduplication guards, and struct registration. A mailer module that declares many templates will have this entire block compiled repeatedly at each call site.

---

```elixir
defmodule MyApp.Mailer.TemplateDSL do
  @moduledoc """
  DSL for registering typed email templates within a mailer module.

  Example:

      defmodule MyApp.Mailer.TransactionalMailer do
        use MyApp.Mailer.TemplateDSL

        email_template :welcome,
          subject:    "Welcome to Acme!",
          required:   [:user_name, :activation_link],
          layout:     MyApp.Mailer.Layouts.Transactional,
          locales:    ~w[en pt-BR es]

        email_template :password_reset,
          subject:   "Reset your password",
          required:  [:user_name, :reset_link, :expires_at],
          layout:    MyApp.Mailer.Layouts.Transactional,
          locales:   ~w[en pt-BR]

        email_template :invoice_ready,
          subject:   "Your invoice is ready",
          required:  [:invoice_number, :total, :due_date, :download_url],
          layout:    MyApp.Mailer.Layouts.Billing,
          locales:   ~w[en pt-BR]
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Mailer.TemplateDSL, only: [email_template: 2]
      Module.register_attribute(__MODULE__, :email_templates, accumulate: true)
      @before_compile MyApp.Mailer.TemplateDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def email_templates, do: @email_templates

      def template(name) do
        Enum.find(@email_templates, fn t -> t.name == name end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to email_template/2 causes
  # VALIDATION: the entire validation pipeline to be expanded and compiled at the
  # VALIDATION: call site: name atom check, subject string check, required
  # VALIDATION: variables list-of-atoms check, layout module compilation and
  # VALIDATION: callback check, locales list-of-binaries check, deduplication
  # VALIDATION: guard, and struct construction. A mailer with 15 templates
  # VALIDATION: compiles this code 15 times instead of delegating once to a
  # VALIDATION: shared helper function.
  defmacro email_template(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "email_template/2: name must be an atom, got #{inspect(name)}"
      end

      subject = Keyword.fetch!(opts, :subject)

      unless is_binary(subject) and byte_size(subject) > 0 do
        raise ArgumentError,
              "email_template/2: :subject must be a non-empty string, got #{inspect(subject)}"
      end

      required = Keyword.get(opts, :required, [])

      unless is_list(required) and Enum.all?(required, &is_atom/1) do
        raise ArgumentError,
              "email_template/2: :required must be a list of atom variable names, " <>
                "got #{inspect(required)}"
      end

      layout = Keyword.get(opts, :layout)

      if not is_nil(layout) do
        unless is_atom(layout) do
          raise ArgumentError,
                "email_template/2: :layout must be a module atom, got #{inspect(layout)}"
        end

        :ok = Code.ensure_compiled!(layout)

        unless function_exported?(layout, :render, 2) do
          raise ArgumentError,
                "email_template/2: layout #{inspect(layout)} must export render/2"
        end
      end

      locales = Keyword.get(opts, :locales, ["en"])

      unless is_list(locales) and Enum.all?(locales, &is_binary/1) do
        raise ArgumentError,
              "email_template/2: :locales must be a list of locale strings, " <>
                "got #{inspect(locales)}"
      end

      if Enum.empty?(locales) do
        raise ArgumentError,
              "email_template/2: :locales must not be empty for template #{inspect(name)}"
      end

      existing = Module.get_attribute(__MODULE__, :email_templates)

      if Enum.any?(existing, fn t -> t.name == name end) do
        raise ArgumentError,
              "email_template/2: duplicate template #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      tmpl = %{
        name:     name,
        subject:  subject,
        required: required,
        layout:   layout,
        locales:  locales
      }

      @email_templates tmpl
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Renders an email for the given template name, assigns, and locale.
  Returns `{:ok, %{subject: binary(), body: binary()}}` or an error tuple.
  """
  @spec render(module(), atom(), map(), String.t()) ::
          {:ok, %{subject: String.t(), body: String.t()}} | {:error, String.t()}
  def render(mailer_module, name, assigns, locale \\ "en") do
    case mailer_module.template(name) do
      nil ->
        {:error, "Unknown email template: #{inspect(name)}"}

      tmpl ->
        missing = Enum.reject(tmpl.required, &Map.has_key?(assigns, &1))

        if missing != [] do
          {:error, "Missing required assigns for template #{inspect(name)}: #{inspect(missing)}"}
        else
          body = apply_layout(tmpl, assigns, locale)
          {:ok, %{subject: tmpl.subject, body: body}}
        end
    end
  end

  defp apply_layout(%{layout: nil}, assigns, _locale),
    do: inspect(assigns)

  defp apply_layout(%{layout: layout}, assigns, locale),
    do: layout.render(assigns, locale)
end
```
