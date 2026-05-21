```elixir
defmodule Auth.EmailValidator do
  use GenServer

  @moduledoc """
  Validates, normalises, and parses email addresses for use during
  registration, invitation, and profile-update flows.
  """

  @email_regex ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$/

  @blocked_domains ~w[
    mailinator.com
    guerrillamail.com
    trashmail.com
    tempmail.com
    throwam.com
    sharklasers.com
    yopmail.com
    maildrop.cc
    dispostable.com
  ]

  @max_local_length  64
  @max_domain_length 255
  @max_total_length  254

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns `{:ok, normalized_email}` or `{:error, reason_atom}`.
  Options: `[allow_blocked_domains: boolean]` (default false).
  """
  def validate(pid, email, opts \\ []) do
    GenServer.call(pid, {:validate, email, opts})
  end

  @doc "Returns `{:ok, %{local: _, domain: _}}` or `{:error, :invalid_format}`."
  def parse_parts(pid, email) do
    GenServer.call(pid, {:parse_parts, email})
  end

  @doc "Lowercases and trims the email, then returns `{:ok, normalized}`."
  def normalize(pid, email) do
    GenServer.call(pid, {:normalize, email})
  end

  @doc "Returns `true` if the domain is not in the blocked list."
  def domain_allowed?(pid, domain) do
    GenServer.call(pid, {:domain_allowed?, domain})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:validate, email, opts}, _from, state) do
    allow_blocked = Keyword.get(opts, :allow_blocked_domains, false)
    normalized    = String.downcase(String.trim(email))

    result =
      with :ok <- check_length(normalized),
           :ok <- check_format(normalized),
           {:ok, %{domain: domain}} <- do_parse_parts(normalized),
           :ok <- check_local_length(normalized),
           :ok <- check_domain_length(domain),
           :ok <- check_blocked_domain(domain, allow_blocked) do
        {:ok, normalized}
      end

    {:reply, result, state}
  end

  def handle_call({:parse_parts, email}, _from, state) do
    {:reply, do_parse_parts(email), state}
  end

  def handle_call({:normalize, email}, _from, state) do
    {:reply, {:ok, String.downcase(String.trim(email))}, state}
  end

  def handle_call({:domain_allowed?, domain}, _from, state) do
    allowed = domain not in @blocked_domains
    {:reply, allowed, state}
  end

  ## Private helpers

  defp do_parse_parts(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> {:ok, %{local: local, domain: domain}}
      _               -> {:error, :invalid_format}
    end
  end

  defp check_length(email) do
    if String.length(email) <= @max_total_length, do: :ok, else: {:error, :email_too_long}
  end

  defp check_format(email) do
    if Regex.match?(@email_regex, email), do: :ok, else: {:error, :invalid_format}
  end

  defp check_local_length(email) do
    [local | _] = String.split(email, "@", parts: 2)
    if String.length(local) <= @max_local_length, do: :ok, else: {:error, :local_part_too_long}
  end

  defp check_domain_length(domain) do
    if String.length(domain) <= @max_domain_length, do: :ok, else: {:error, :domain_too_long}
  end

  defp check_blocked_domain(_domain, true), do: :ok
  defp check_blocked_domain(domain, false) do
    if domain in @blocked_domains, do: {:error, :disposable_email_domain}, else: :ok
  end

end
```
