```elixir
defmodule Auth.TokenInspector do
  use GenServer

  @moduledoc """
  Parses and inspects JWT access tokens without cryptographic verification.
  Used by middleware to extract claims for logging, rate limiting, and routing
  before forwarding to the authoritative verification service.
  """



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Parses the JWT and returns the claims map, or `{:error, reason}`.
  Does NOT verify the signature.
  """
  def parse_claims(pid, token) do
    GenServer.call(pid, {:parse_claims, token})
  end

  @doc """
  Returns `true` if the token's `exp` claim is in the past.
  """
  def expired?(pid, token) do
    GenServer.call(pid, {:expired, token})
  end

  @doc """
  Extracts the `sub` (subject) claim from the token.
  """
  def extract_subject(pid, token) do
    GenServer.call(pid, {:extract_subject, token})
  end

  @doc """
  Returns the list of scopes from the `scope` claim, split on whitespace.
  """
  def scopes(pid, token) do
    GenServer.call(pid, {:scopes, token})
  end

  @doc """
  Returns the token header claims (alg, typ, kid).
  """
  def header(pid, token) do
    GenServer.call(pid, {:header, token})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:parse_claims, token}, _from, state) do
    {:reply, decode_payload(token), state}
  end

  @impl true
  def handle_call({:expired, token}, _from, state) do
    result =
      with {:ok, claims} <- decode_payload(token),
           exp when not is_nil(exp) <- Map.get(claims, "exp") do
        now = System.system_time(:second)
        {:ok, now > exp}
      else
        nil -> {:error, "Token has no exp claim"}
        err -> err
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:extract_subject, token}, _from, state) do
    result =
      with {:ok, claims} <- decode_payload(token) do
        case Map.get(claims, "sub") do
          nil -> {:error, "Token has no sub claim"}
          sub -> {:ok, sub}
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:scopes, token}, _from, state) do
    result =
      with {:ok, claims} <- decode_payload(token) do
        scope_string = Map.get(claims, "scope", "")
        {:ok, String.split(scope_string, " ", trim: true)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:header, token}, _from, state) do
    {:reply, decode_header(token), state}
  end

  defp decode_payload(token) do
    with [_header, payload, _sig] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, "Malformed JWT token"}
    end
  end

  defp decode_header(token) do
    with [header | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(header, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, "Malformed JWT header"}
    end
  end
end
```
