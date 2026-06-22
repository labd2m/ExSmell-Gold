```elixir
defmodule Errors.Catalogue do
  @moduledoc """
  Defines a typed catalogue of domain errors with machine-readable codes,
  user-facing messages, HTTP status mappings, and optional recovery hints.
  Centralising error definitions ensures that API responses, log entries,
  and monitoring alerts all use consistent codes and messages, and that
  adding a new error type automatically propagates to every layer that
  renders it.
  """

  @type error_code :: atom()
  @type http_status :: 400..599
  @type severity :: :info | :warning | :error | :critical

  @type error_entry :: %{
          code: error_code(),
          message: binary(),
          http_status: http_status(),
          severity: severity(),
          retryable: boolean(),
          recovery_hint: binary() | nil
        }

  @catalogue %{
    # Authentication and authorisation
    unauthenticated: %{
      code: :unauthenticated, message: "Authentication is required to access this resource.",
      http_status: 401, severity: :warning, retryable: false,
      recovery_hint: "Provide a valid Bearer token in the Authorization header."
    },
    token_expired: %{
      code: :token_expired, message: "Your session has expired.",
      http_status: 401, severity: :info, retryable: true,
      recovery_hint: "Obtain a new token by authenticating again."
    },
    forbidden: %{
      code: :forbidden, message: "You do not have permission to perform this action.",
      http_status: 403, severity: :warning, retryable: false,
      recovery_hint: nil
    },

    # Resource errors
    not_found: %{
      code: :not_found, message: "The requested resource does not exist.",
      http_status: 404, severity: :info, retryable: false,
      recovery_hint: "Verify the resource identifier and try again."
    },
    conflict: %{
      code: :conflict, message: "The request conflicts with the current state of the resource.",
      http_status: 409, severity: :warning, retryable: false,
      recovery_hint: "Fetch the latest resource state and reapply your changes."
    },
    gone: %{
      code: :gone, message: "This resource has been permanently deleted.",
      http_status: 410, severity: :info, retryable: false,
      recovery_hint: nil
    },

    # Validation
    validation_failed: %{
      code: :validation_failed, message: "One or more fields failed validation.",
      http_status: 422, severity: :info, retryable: false,
      recovery_hint: "Review the errors field for per-field details."
    },
    payload_too_large: %{
      code: :payload_too_large, message: "The request payload exceeds the size limit.",
      http_status: 413, severity: :warning, retryable: false,
      recovery_hint: "Reduce the payload size or use chunked upload."
    },

    # Rate limiting
    rate_limited: %{
      code: :rate_limited, message: "Too many requests. Please slow down.",
      http_status: 429, severity: :warning, retryable: true,
      recovery_hint: "Wait for the duration indicated by the Retry-After header."
    },

    # Server errors
    internal_error: %{
      code: :internal_error, message: "An unexpected error occurred. Our team has been notified.",
      http_status: 500, severity: :error, retryable: true,
      recovery_hint: "Retry the request. Contact support if the error persists."
    },
    service_unavailable: %{
      code: :service_unavailable, message: "The service is temporarily unavailable.",
      http_status: 503, severity: :error, retryable: true,
      recovery_hint: "Retry the request after a short delay."
    },
    gateway_timeout: %{
      code: :gateway_timeout, message: "A downstream service did not respond in time.",
      http_status: 504, severity: :error, retryable: true,
      recovery_hint: "Retry the request. If the problem persists, contact support."
    }
  }

  @doc """
  Returns the `error_entry` for `code`, or `nil` when not registered.
  """
  @spec fetch(error_code()) :: error_entry() | nil
  def fetch(code) when is_atom(code), do: Map.get(@catalogue, code)

  @doc """
  Returns the `error_entry` for `code`, raising when not registered.
  """
  @spec fetch!(error_code()) :: error_entry()
  def fetch!(code) when is_atom(code) do
    Map.fetch!(@catalogue, code)
  rescue
    KeyError -> raise ArgumentError, "Unknown error code #{inspect(code)}"
  end

  @doc """
  Returns the HTTP status code for `error_code`. Defaults to `500` for
  unregistered codes so unknown errors are always treated as server errors.
  """
  @spec http_status(error_code()) :: http_status()
  def http_status(code) when is_atom(code) do
    case fetch(code) do
      nil -> 500
      entry -> entry.http_status
    end
  end

  @doc """
  Returns `true` when the error is considered retryable.
  """
  @spec retryable?(error_code()) :: boolean()
  def retryable?(code) when is_atom(code) do
    case fetch(code) do
      nil -> false
      entry -> entry.retryable
    end
  end

  @doc """
  Returns all registered error codes grouped by HTTP status family
  (4xx, 5xx).
  """
  @spec by_status_family() :: %{binary() => [error_code()]}
  def by_status_family do
    Enum.group_by(@catalogue, fn {_code, entry} ->
      if entry.http_status >= 500, do: "5xx", else: "4xx"
    end, fn {code, _entry} -> code end)
  end

  @doc """
  Formats an error as a JSON-encodable map for API responses.
  """
  @spec to_response(error_code(), binary() | nil) :: map()
  def to_response(code, detail \\ nil) when is_atom(code) do
    entry = fetch(code) || fetch!(:internal_error)

    %{
      error: entry.code,
      message: entry.message,
      detail: detail,
      retryable: entry.retryable,
      recovery_hint: entry.recovery_hint
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
```
