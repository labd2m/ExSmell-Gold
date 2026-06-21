```elixir
defmodule AppError do
  @moduledoc """
  Centralised typed error catalogue for the application.

  Every domain error is declared here with a unique code, a default message,
  an HTTP status code for API responses, and an optional i18n key for
  client-facing localisation. Centralising errors in one module makes them
  discoverable, prevents code-duplication across contexts, and provides a
  single place to map domain failures to HTTP responses.
  """

  @type code :: atom()

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          http_status: non_neg_integer(),
          i18n_key: String.t() | nil,
          detail: term()
        }

  defstruct [:code, :message, :http_status, :i18n_key, detail: nil]

  @catalogue %{
    not_found:            {404, "Resource not found",            "errors.not_found"},
    unauthorized:         {401, "Authentication required",       "errors.unauthorized"},
    forbidden:            {403, "Access denied",                 "errors.forbidden"},
    validation_failed:    {422, "Validation failed",             "errors.validation_failed"},
    conflict:             {409, "Resource already exists",       "errors.conflict"},
    rate_limited:         {429, "Too many requests",             "errors.rate_limited"},
    service_unavailable:  {503, "Service temporarily unavailable", "errors.service_unavailable"},
    payment_declined:     {402, "Payment was declined",          "errors.payment_declined"},
    quota_exceeded:       {429, "Usage quota exceeded",          "errors.quota_exceeded"},
    invalid_token:        {401, "Token is invalid or expired",   "errors.invalid_token"},
    stale_data:           {409, "Data was modified by another request", "errors.stale_data"},
    unsupported_media:    {415, "Unsupported media type",        "errors.unsupported_media"},
    internal_error:       {500, "An unexpected error occurred",  "errors.internal_error"}
  }

  @spec build(code(), term()) :: t()
  def build(code, detail \\ nil) when is_atom(code) do
    case Map.fetch(@catalogue, code) do
      {:ok, {http_status, message, i18n_key}} ->
        %__MODULE__{
          code: code,
          message: message,
          http_status: http_status,
          i18n_key: i18n_key,
          detail: detail
        }

      :error ->
        %__MODULE__{
          code: :internal_error,
          message: "An unexpected error occurred",
          http_status: 500,
          i18n_key: "errors.internal_error",
          detail: {:unknown_code, code, detail}
        }
    end
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = error) do
    base = %{"code" => Atom.to_string(error.code), "message" => error.message}

    if error.detail do
      Map.put(base, "detail", inspect(error.detail))
    else
      base
    end
  end

  @spec http_status(code()) :: non_neg_integer()
  def http_status(code) when is_atom(code) do
    case Map.fetch(@catalogue, code) do
      {:ok, {status, _, _}} -> status
      :error -> 500
    end
  end

  @spec known_codes() :: [code()]
  def known_codes, do: Map.keys(@catalogue)

  @spec not_found(term()) :: t()
  def not_found(detail \\ nil), do: build(:not_found, detail)

  @spec unauthorized(term()) :: t()
  def unauthorized(detail \\ nil), do: build(:unauthorized, detail)

  @spec forbidden(term()) :: t()
  def forbidden(detail \\ nil), do: build(:forbidden, detail)

  @spec validation_failed(term()) :: t()
  def validation_failed(detail \\ nil), do: build(:validation_failed, detail)
end
```
