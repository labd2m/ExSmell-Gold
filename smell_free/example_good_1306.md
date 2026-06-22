**File:** `example_good_1306.md`

```elixir
defmodule DomainError do
  @moduledoc """
  A structured domain error type carrying a machine-readable code,
  a human-readable message, an HTTP status hint, and optional metadata.
  """

  @enforce_keys [:code, :message, :status]
  defstruct [:code, :message, :status, :detail, :meta]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          status: pos_integer(),
          detail: String.t() | nil,
          meta: map() | nil
        }

  @spec new(atom(), String.t(), pos_integer(), keyword()) :: t()
  def new(code, message, status, opts \\ []) do
    %__MODULE__{
      code: code,
      message: message,
      status: status,
      detail: Keyword.get(opts, :detail),
      meta: Keyword.get(opts, :meta)
    }
  end
end

defmodule DomainError.Catalogue do
  @moduledoc """
  Canonical constructor functions for all domain errors used across the application.
  New error types are added here; call sites import only this module.
  """

  alias DomainError

  @spec not_found(String.t(), String.t()) :: DomainError.t()
  def not_found(resource_type, id) do
    DomainError.new(
      :not_found,
      "#{resource_type} not found",
      404,
      detail: "No #{resource_type} exists with id #{id}"
    )
  end

  @spec forbidden(String.t()) :: DomainError.t()
  def forbidden(action) do
    DomainError.new(
      :forbidden,
      "You are not authorized to perform this action",
      403,
      detail: "Action denied: #{action}"
    )
  end

  @spec validation_failed([{atom(), String.t()}]) :: DomainError.t()
  def validation_failed(field_errors) when is_list(field_errors) do
    DomainError.new(
      :validation_failed,
      "Validation failed",
      422,
      meta: %{fields: Map.new(field_errors, fn {f, msg} -> {f, [msg]} end)}
    )
  end

  @spec conflict(String.t()) :: DomainError.t()
  def conflict(description) do
    DomainError.new(:conflict, "Conflict", 409, detail: description)
  end

  @spec rate_limited(pos_integer()) :: DomainError.t()
  def rate_limited(retry_after_seconds) do
    DomainError.new(
      :rate_limited,
      "Too many requests",
      429,
      meta: %{retry_after_seconds: retry_after_seconds}
    )
  end

  @spec service_unavailable(String.t()) :: DomainError.t()
  def service_unavailable(dependency) do
    DomainError.new(
      :service_unavailable,
      "A required service is currently unavailable",
      503,
      detail: "Dependency failed: #{dependency}"
    )
  end

  @spec unprocessable(String.t()) :: DomainError.t()
  def unprocessable(reason) do
    DomainError.new(:unprocessable, "Request could not be processed", 422, detail: reason)
  end
end

defmodule DomainError.Renderer do
  @moduledoc """
  Serializes a DomainError into a JSON-encodable map suitable
  for inclusion in an API error response body.
  """

  alias DomainError

  @spec to_map(DomainError.t()) :: map()
  def to_map(%DomainError{} = error) do
    base = %{
      error: %{
        code: error.code,
        message: error.message
      }
    }

    base
    |> maybe_put_detail(error.detail)
    |> maybe_put_meta(error.meta)
  end

  @spec http_status(DomainError.t()) :: pos_integer()
  def http_status(%DomainError{status: status}), do: status

  defp maybe_put_detail(map, nil), do: map
  defp maybe_put_detail(map, detail), do: put_in(map, [:error, :detail], detail)

  defp maybe_put_meta(map, nil), do: map
  defp maybe_put_meta(map, meta), do: put_in(map, [:error, :meta], meta)
end
```
