```elixir
defmodule APIResponse.Envelope do
  @moduledoc """
  A canonical response envelope for all outbound API payloads.
  Success and error responses share a uniform top-level shape so
  clients can apply a single deserialization strategy.
  """

  @type meta :: %{request_id: String.t(), timestamp: String.t()}
  @type t :: %__MODULE__{ok: boolean(), data: term(), error: map() | nil, meta: meta()}

  defstruct [:ok, :data, :error, :meta]

  @spec success(term(), String.t()) :: t()
  def success(data, request_id) when is_binary(request_id) do
    %__MODULE__{ok: true, data: data, error: nil, meta: build_meta(request_id)}
  end

  @spec failure(String.t(), String.t(), keyword()) :: t()
  def failure(code, message, opts \\ [])
      when is_binary(code) and is_binary(message) do
    request_id = Keyword.get(opts, :request_id, generate_id())
    details = Keyword.get(opts, :details, [])

    %__MODULE__{
      ok: false,
      data: nil,
      error: %{code: code, message: message, details: details},
      meta: build_meta(request_id)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{ok: true} = env) do
    %{"ok" => true, "data" => env.data, "error" => nil, "meta" => format_meta(env.meta)}
  end

  def to_map(%__MODULE__{ok: false} = env) do
    %{"ok" => false, "data" => nil, "error" => env.error, "meta" => format_meta(env.meta)}
  end

  defp build_meta(request_id) do
    %{request_id: request_id, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  defp format_meta(%{request_id: rid, timestamp: ts}) do
    %{"request_id" => rid, "timestamp" => ts}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

defmodule APIResponse.Normalizer do
  @moduledoc """
  Maps application-level results and Ecto changesets to structured
  `APIResponse.Envelope` values. Controllers delegate to this module
  so error-translation logic is centralized in one place.
  """

  alias APIResponse.Envelope

  @type source_result :: {:ok, term()} | {:error, atom()} | {:error, Ecto.Changeset.t()}

  @spec from_result(source_result(), String.t()) :: Envelope.t()
  def from_result({:ok, data}, request_id) when is_binary(request_id) do
    Envelope.success(data, request_id)
  end

  def from_result({:error, %Ecto.Changeset{} = changeset}, request_id) do
    details = format_changeset_errors(changeset)
    Envelope.failure("VALIDATION_ERROR", "One or more fields are invalid",
      request_id: request_id, details: details)
  end

  def from_result({:error, :not_found}, request_id) do
    Envelope.failure("NOT_FOUND", "The requested resource does not exist", request_id: request_id)
  end

  def from_result({:error, :forbidden}, request_id) do
    Envelope.failure("FORBIDDEN", "You do not have permission to perform this action", request_id: request_id)
  end

  def from_result({:error, :conflict}, request_id) do
    Envelope.failure("CONFLICT", "A resource with these attributes already exists", request_id: request_id)
  end

  def from_result({:error, :invalid_transition}, request_id) do
    Envelope.failure("INVALID_STATE_TRANSITION", "This operation is not allowed in the current state", request_id: request_id)
  end

  def from_result({:error, _unknown}, request_id) do
    Envelope.failure("INTERNAL_ERROR", "An unexpected error occurred", request_id: request_id)
  end

  @spec from_paginated({:ok, list(term()), map()} | {:error, atom()}, String.t()) :: Envelope.t()
  def from_paginated({:ok, entries, pagination}, request_id) do
    data = %{entries: entries, pagination: pagination}
    Envelope.success(data, request_id)
  end

  def from_paginated({:error, _} = err, request_id) do
    from_result(err, request_id)
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn msg -> %{field: field, message: msg} end)
    end)
  end
end
```
