```elixir
defmodule Analytics.FunnelReport do
  @moduledoc """
  Generates funnel analysis reports showing step-by-step conversion
  and drop-off rates for user acquisition and activation flows.
  """

  alias Analytics.Repo
  alias Analytics.Event

  @doc """
  Calculates the conversion rate between two funnel steps within a date range.
  Returns a float between 0.0 and 1.0.
  """
  def conversion_rate(from_step, to_step, %{start_date: start_date, end_date: end_date}) do
    from_users =
      Repo.all_by(Event, name: from_step, after: start_date, before: end_date)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    to_users =
      Repo.all_by(Event, name: to_step, after: start_date, before: end_date)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    if from_users == 0 do
      0.0
    else
      Float.round(to_users / from_users, 4)
    end
  end

  @doc """
  Calculates the drop-off rate between two funnel steps within a date range.
  Returns the percentage of users who did not proceed from `from_step` to `to_step`.
  """
  def drop_off_rate(from_step, to_step, %{start_date: start_date, end_date: end_date}) do
    from_users =
      Repo.all_by(Event, name: from_step, after: start_date, before: end_date)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    to_users =
      Repo.all_by(Event, name: to_step, after: start_date, before: end_date)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    if from_users == 0 do
      0.0
    else
      dropped = from_users - to_users
      Float.round(dropped / from_users * 100, 2)
    end
  end

  @doc """
  Builds a full funnel report for a sequence of steps over a date range.
  Returns a list of maps with step, user count, conversion, and drop-off.
  """
  def full_funnel(steps, date_range) when is_list(steps) and length(steps) >= 2 do
    steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      %{
        from_step: from,
        to_step: to,
        conversion_rate: conversion_rate(from, to, date_range),
        drop_off_rate: drop_off_rate(from, to, date_range)
      }
    end)
  end

  @doc """
  Returns the step with the highest drop-off rate in a funnel.
  """
  def worst_step(steps, date_range) do
    full_funnel(steps, date_range)
    |> Enum.max_by(& &1.drop_off_rate)
  end
end
```
