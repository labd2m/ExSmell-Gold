```elixir
defmodule Contracts.Clause do
  @moduledoc """
  A single named clause within a contract template. Clauses carry a body
  template string with named interpolation placeholders and an optional
  set of required variable keys that must be supplied before rendering.
  """

  @enforce_keys [:key, :title, :body_template]
  defstruct [:key, :title, :body_template, :required_variables, :optional]

  @type t :: %__MODULE__{
          key: atom(),
          title: String.t(),
          body_template: String.t(),
          required_variables: list(atom()),
          optional: boolean()
        }

  @spec new(atom(), String.t(), String.t(), keyword()) :: t()
  def new(key, title, body_template, opts \\ [])
      when is_atom(key) and is_binary(title) and is_binary(body_template) do
    %__MODULE__{
      key: key,
      title: title,
      body_template: body_template,
      required_variables: Keyword.get(opts, :required_variables, []),
      optional: Keyword.get(opts, :optional, false)
    }
  end

  @spec render(t(), map()) :: {:ok, String.t()} | {:error, {:missing_variables, list(atom())}}
  def render(%__MODULE__{body_template: template, required_variables: required}, bindings)
      when is_map(bindings) do
    missing = Enum.reject(required, &Map.has_key?(bindings, &1))

    if Enum.empty?(missing) do
      rendered = Enum.reduce(bindings, template, fn {key, value}, acc ->
        String.replace(acc, "{{#{key}}}", to_string(value))
      end)
      {:ok, rendered}
    else
      {:error, {:missing_variables, missing}}
    end
  end
end

defmodule Contracts.Template do
  @moduledoc """
  A versioned contract template composed of an ordered set of clauses.
  Templates are validated at construction time and rendered by supplying
  a variable binding map that satisfies all required clause variables.
  """

  alias Contracts.Clause

  @enforce_keys [:id, :name, :version, :clauses]
  defstruct [:id, :name, :version, :clauses, :description]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          clauses: list(Clause.t()),
          description: String.t() | nil
        }

  @spec new(String.t(), String.t(), list(Clause.t()), keyword()) ::
          {:ok, t()} | {:error, :duplicate_clause_keys}
  def new(name, version, clauses, opts \\ [])
      when is_binary(name) and is_binary(version) and is_list(clauses) do
    keys = Enum.map(clauses, & &1.key)

    if length(keys) == length(Enum.uniq(keys)) do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         name: name,
         version: version,
         clauses: clauses,
         description: Keyword.get(opts, :description)
       }}
    else
      {:error, :duplicate_clause_keys}
    end
  end

  @spec required_variables(t()) :: list(atom())
  def required_variables(%__MODULE__{clauses: clauses}) do
    clauses
    |> Enum.flat_map(& &1.required_variables)
    |> Enum.uniq()
  end

  @spec render(t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(%__MODULE__{clauses: clauses, name: name, version: version}, bindings)
      when is_map(bindings) do
    {rendered_sections, errors} =
      clauses
      |> Enum.reject(&(&1.optional and not has_any_binding?(&1, bindings)))
      |> Enum.reduce({[], []}, fn clause, {sections, errs} ->
        case Clause.render(clause, bindings) do
          {:ok, body} ->
            section = format_section(clause.title, body)
            {[section | sections], errs}

          {:error, {:missing_variables, missing}} ->
            {sections, [{clause.key, missing} | errs]}
        end
      end)

    if Enum.empty?(errors) do
      header = "#{name} — Version #{version}\n#{String.duplicate("=", 60)}\n\n"
      body = rendered_sections |> Enum.reverse() |> Enum.join("\n\n")
      {:ok, header <> body}
    else
      {:error, {:render_errors, Enum.reverse(errors)}}
    end
  end

  defp has_any_binding?(%Clause{required_variables: required}, bindings) do
    Enum.any?(required, &Map.has_key?(bindings, &1))
  end

  defp format_section(title, body) do
    underline = String.duplicate("-", String.length(title))
    "#{title}\n#{underline}\n#{body}"
  end

  defp generate_id do
    :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
  end
end

defmodule Contracts.Signer do
  @moduledoc """
  Applies a cryptographic signature to a rendered contract document.
  The signature binds the document content to the signer's identity
  and a timestamp, producing a tamper-evident audit record.
  """

  @type signature :: %{
          signer_id: integer(),
          document_hash: String.t(),
          signed_at: DateTime.t(),
          signature: String.t()
        }

  @spec sign(String.t(), integer(), String.t()) ::
          {:ok, signature()} | {:error, :signing_failed}
  def sign(document, signer_id, signing_key)
      when is_binary(document) and is_integer(signer_id) and is_binary(signing_key) do
    document_hash = hash_document(document)
    signed_at = DateTime.utc_now()
    payload = "#{signer_id}:#{document_hash}:#{DateTime.to_iso8601(signed_at)}"

    case produce_signature(payload, signing_key) do
      {:ok, sig} ->
        {:ok,
         %{
           signer_id: signer_id,
           document_hash: document_hash,
           signed_at: signed_at,
           signature: sig
         }}

      :error ->
        {:error, :signing_failed}
    end
  end

  @spec verify(String.t(), signature(), String.t()) :: :ok | {:error, atom()}
  def verify(document, %{document_hash: stored_hash, signer_id: signer_id,
                          signed_at: signed_at, signature: sig}, signing_key)
      when is_binary(document) and is_binary(signing_key) do
    actual_hash = hash_document(document)

    cond do
      actual_hash != stored_hash ->
        {:error, :document_tampered}

      not valid_signature?(signer_id, stored_hash, signed_at, sig, signing_key) ->
        {:error, :invalid_signature}

      true ->
        :ok
    end
  end

  defp hash_document(document) do
    :crypto.hash(:sha256, document) |> Base.url_encode64(padding: false)
  end

  defp produce_signature(payload, key) do
    sig =
      :crypto.mac(:hmac, :sha256, key, payload)
      |> Base.url_encode64(padding: false)

    {:ok, sig}
  rescue
    _ -> :error
  end

  defp valid_signature?(signer_id, hash, signed_at, sig, key) do
    payload = "#{signer_id}:#{hash}:#{DateTime.to_iso8601(signed_at)}"
    {:ok, expected} = produce_signature(payload, key)
    Plug.Crypto.secure_compare(sig, expected)
  end
end
```
