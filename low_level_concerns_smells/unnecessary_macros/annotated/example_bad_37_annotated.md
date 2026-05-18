# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `API.ErrorResponse` module, `build_error/3` macro |
| **Affected function(s)** | `build_error/3` |
| **Short explanation** | `build_error/3` assembles an error response map from three runtime arguments. This is a pure data-construction operation with no compile-time component; a regular function with pattern-matched heads for different error codes would be idiomatic and simpler. |

```elixir
defmodule API.ErrorResponse do
  @moduledoc """
  Builds structured JSON-API-compatible error response bodies for the
  REST API layer. Ensures consistent error shapes across all endpoints.
  """

  @api_version "v2"
  @support_url "https://support.example.com/errors"

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `build_error/3` constructs a plain
  # Elixir map from three runtime string/atom values. All three arguments
  # are only known at runtime, so no compile-time expansion is possible or
  # useful. A `def` function with optional default arguments would achieve
  # exactly the same result with far less ceremony and no `require` burden
  # on the callers.
  defmacro build_error(code, title, detail) do
    quote do
      %{
        errors: [
          %{
            status: to_string(unquote(code)),
            title: unquote(title),
            detail: unquote(detail),
            source: %{},
            links: %{about: "#{unquote(@support_url)}/#{unquote(code)}"},
            meta: %{api_version: unquote(@api_version)}
          }
        ]
      }
    end
  end
  # VALIDATION: SMELL END

  def not_found(resource, id) do
    require API.ErrorResponse
    API.ErrorResponse.build_error(404, "Not Found", "#{resource} with id=#{id} was not found")
  end

  def unauthorized(reason \\ "Authentication required") do
    require API.ErrorResponse
    API.ErrorResponse.build_error(401, "Unauthorized", reason)
  end

  def forbidden(action) do
    require API.ErrorResponse
    API.ErrorResponse.build_error(403, "Forbidden", "You are not allowed to #{action}")
  end

  def unprocessable(changeset_errors) do
    require API.ErrorResponse
    detail = Enum.map_join(changeset_errors, "; ", fn {field, msg} -> "#{field} #{msg}" end)
    API.ErrorResponse.build_error(422, "Unprocessable Entity", detail)
  end

  def rate_limited(retry_after_seconds) do
    require API.ErrorResponse
    API.ErrorResponse.build_error(
      429,
      "Too Many Requests",
      "Rate limit exceeded. Retry after #{retry_after_seconds}s"
    )
  end

  def internal_server_error(trace_id) do
    require API.ErrorResponse
    API.ErrorResponse.build_error(
      500,
      "Internal Server Error",
      "An unexpected error occurred. Trace ID: #{trace_id}"
    )
  end

  def service_unavailable(eta_seconds) do
    require API.ErrorResponse
    API.ErrorResponse.build_error(
      503,
      "Service Unavailable",
      "The service is temporarily unavailable. Expected recovery in #{eta_seconds}s"
    )
  end

  def conflict(entity, field, value) do
    require API.ErrorResponse
    API.ErrorResponse.build_error(
      409,
      "Conflict",
      "#{entity} with #{field}=#{value} already exists"
    )
  end

  def to_json(error_body) do
    Jason.encode!(error_body)
  end
end
```
