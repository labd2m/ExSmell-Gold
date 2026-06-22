**File:** `example_good_1063.md`

```elixir
defmodule Mailer do
  @moduledoc """
  Transport-agnostic email dispatch library. All configuration is passed
  at call time via keyword options, enabling callers to use multiple
  transport adapters within the same application.
  """

  alias Mailer.{Message, Adapters}

  @type transport :: :smtp | :sendgrid | :ses
  @type send_opts :: [
          transport: transport(),
          api_key: String.t(),
          region: String.t(),
          timeout_ms: pos_integer()
        ]

  @spec send(Message.t(), send_opts()) :: :ok | {:error, term()}
  def send(%Message{} = message, opts) when is_list(opts) do
    with {:ok, transport} <- resolve_transport(opts),
         {:ok, adapter} <- load_adapter(transport),
         :ok <- validate_message(message) do
      adapter.deliver(message, opts)
    end
  end

  @spec send_batch([Message.t()], send_opts()) :: {:ok, map()} | {:error, term()}
  def send_batch(messages, opts) when is_list(messages) and is_list(opts) do
    results =
      messages
      |> Task.async_stream(&send(&1, opts), timeout: Keyword.get(opts, :timeout_ms, 30_000))
      |> Enum.reduce(%{ok: 0, error: []}, &accumulate_result/2)

    if results.error == [] do
      {:ok, results}
    else
      {:error, {:partial_failure, results}}
    end
  end

  defp resolve_transport(opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, t} when t in [:smtp, :sendgrid, :ses] -> {:ok, t}
      {:ok, unknown} -> {:error, {:unknown_transport, unknown}}
      :error -> {:error, :transport_required}
    end
  end

  defp load_adapter(:smtp), do: {:ok, Adapters.Smtp}
  defp load_adapter(:sendgrid), do: {:ok, Adapters.Sendgrid}
  defp load_adapter(:ses), do: {:ok, Adapters.Ses}

  defp validate_message(%Message{to: to, subject: subject, body: body}) do
    cond do
      not valid_email?(to) -> {:error, {:invalid_recipient, to}}
      subject == "" or is_nil(subject) -> {:error, :blank_subject}
      body == "" or is_nil(body) -> {:error, :blank_body}
      true -> :ok
    end
  end

  defp valid_email?(address) when is_binary(address) do
    Regex.match?(~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, address)
  end

  defp valid_email?(_), do: false

  defp accumulate_result({:ok, :ok}, acc), do: Map.update!(acc, :ok, &(&1 + 1))

  defp accumulate_result({:ok, {:error, reason}}, acc) do
    Map.update!(acc, :error, &[reason | &1])
  end

  defp accumulate_result({:exit, reason}, acc) do
    Map.update!(acc, :error, &[{:task_exit, reason} | &1])
  end
end

defmodule Mailer.Message do
  @moduledoc "Struct representing an outbound email message."

  @enforce_keys [:to, :from, :subject]
  defstruct [:to, :from, :subject, :body, :html_body, :reply_to, cc: [], bcc: [], attachments: []]

  @type t :: %__MODULE__{
          to: String.t(),
          from: String.t(),
          subject: String.t(),
          body: String.t() | nil,
          html_body: String.t() | nil,
          reply_to: String.t() | nil,
          cc: [String.t()],
          bcc: [String.t()],
          attachments: [map()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    msg = struct!(__MODULE__, attrs)
    {:ok, msg}
  rescue
    err -> {:error, err}
  end
end
```
