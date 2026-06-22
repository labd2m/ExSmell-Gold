```elixir
defmodule Mailer.Config do
  @moduledoc """
  Validates and normalises configuration for the outbound mailer.
  All accepted options, their types, defaults, and documentation are
  declared in a single `NimbleOptions` schema. Validation is performed once
  at startup so runtime callers never encounter cryptic KeyErrors or type
  mismatches; they always work with a fully validated, typed configuration
  struct produced by `validate!/1`.
  """

  @schema NimbleOptions.new!(
    adapter: [
      type: {:in, [:smtp, :sendgrid, :ses, :test]},
      required: true,
      doc: "The delivery adapter to use."
    ],
    from_address: [
      type: :string,
      required: true,
      doc: "The default From address for all outbound mail."
    ],
    from_name: [
      type: :string,
      default: "MyApp",
      doc: "The display name shown alongside the From address."
    ],
    reply_to: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Optional Reply-To address applied to every message."
    ],
    smtp: [
      type: :keyword_list,
      default: [],
      doc: "SMTP-specific options. Ignored for non-SMTP adapters.",
      keys: [
        host: [type: :string, required: true],
        port: [type: :pos_integer, default: 587],
        tls: [type: {:in, [:always, :never, :if_available]}, default: :always],
        username: [type: :string, required: true],
        password: [type: :string, required: true],
        timeout_ms: [type: :pos_integer, default: 15_000]
      ]
    ],
    sendgrid: [
      type: :keyword_list,
      default: [],
      doc: "SendGrid-specific options. Ignored for non-SendGrid adapters.",
      keys: [
        api_key: [type: :string, required: true],
        sandbox: [type: :boolean, default: false]
      ]
    ],
    rate_limit: [
      type: :keyword_list,
      default: [],
      keys: [
        per_second: [type: :pos_integer, default: 50],
        burst: [type: :pos_integer, default: 200]
      ]
    ],
    retry: [
      type: :keyword_list,
      default: [],
      keys: [
        max_attempts: [type: :pos_integer, default: 3],
        base_delay_ms: [type: :pos_integer, default: 500]
      ]
    ],
    open_tracking: [type: :boolean, default: true],
    click_tracking: [type: :boolean, default: true],
    unsubscribe_footer: [type: :boolean, default: true]
  )

  @type t :: keyword()

  @doc """
  Validates `opts` against the mailer configuration schema.
  Returns `{:ok, validated_opts}` or `{:error, %NimbleOptions.ValidationError{}}`.
  """
  @spec validate(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(opts) when is_list(opts) do
    NimbleOptions.validate(opts, @schema)
  end

  @doc """
  Validates `opts` and raises `ArgumentError` on failure. Use this during
  application startup where misconfiguration should abort the boot sequence.
  """
  @spec validate!(keyword()) :: t()
  def validate!(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, valid} ->
        valid

      {:error, error} ->
        raise ArgumentError, """
        Invalid mailer configuration:

        #{Exception.message(error)}

        See Mailer.Config documentation for accepted options.
        """
    end
  end

  @doc """
  Returns the NimbleOptions documentation string for the full schema.
  Useful for embedding in module docs or generating configuration guides.
  """
  @spec docs() :: binary()
  def docs do
    NimbleOptions.docs(@schema)
  end

  @doc """
  Returns the validated configuration from the application environment,
  raising if the configuration is absent or invalid.
  """
  @spec from_application_env!() :: t()
  def from_application_env! do
    opts = Application.get_env(:my_app, Mailer.Config, [])
    validate!(opts)
  end
end
```
