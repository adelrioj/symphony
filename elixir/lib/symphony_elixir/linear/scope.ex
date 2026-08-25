defmodule SymphonyElixir.Linear.Scope do
  @moduledoc """
  Owns the Linear read scope: validation, `IssueFilter` construction, and the
  human-readable summary the status board renders.

  Scope keys live under `tracker.provider` because `SPEC.md` §5.3.1 makes that
  object adapter-owned and forbids core from prescribing a cross-provider scope
  schema. This module is the only place that knows their names.

  One module owns all three concerns so the query, the config error, and the
  board text cannot drift apart.

  Team keys, label names, and state names are matched with `eqIgnoreCase`
  because Linear's `StringComparator` offers `in` but no `inIgnoreCase`, so a
  case-insensitive set match has to be an `or` list of single comparisons.

  Top-level `IssueFilter` keys AND with the `and` conjunct list, so a filter
  reads as `state AND cycle AND (team ...) AND project AND (any label ...) AND
  required label ...`.
  """

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(tracker_settings) when is_map(tracker_settings) do
    provider = provider_map(tracker_settings)

    # Type checks run first so a malformed value can never satisfy the presence rule.
    with :ok <- validate_team_keys_shape(provider),
         :ok <- validate_current_cycle_shape(provider),
         :ok <- validate_scope_present(tracker_settings) do
      validate_cycle_is_team_qualified(tracker_settings)
    end
  end

  @doc """
  Builds the Linear `IssueFilter` map for the configured scope.

  `opts` accepts `:state_names` only, and an unknown key raises: there is
  deliberately no `:ids` option, because the by-IDs refresh read applies no
  scope and giving this function an ID mode is what would make a scoped ID read
  representable. Rejecting unknown keys also means a typo like `state_name:`
  cannot silently yield a query with no state filter at all.
  """
  @spec filter(map(), keyword()) :: map()
  def filter(tracker_settings, opts \\ []) when is_map(tracker_settings) and is_list(opts) do
    opts = Keyword.validate!(opts, [:state_names])

    conjuncts =
      [
        team_conjunct(team_keys(tracker_settings)),
        project_conjunct(project_slug(tracker_settings)),
        any_labels_conjunct(label_list(tracker_settings, :any_labels))
      ] ++ required_label_conjuncts(label_list(tracker_settings, :required_labels))

    %{}
    |> maybe_put_state(Keyword.get(opts, :state_names))
    |> maybe_put_cycle(current_cycle?(tracker_settings))
    |> maybe_put_conjuncts(Enum.reject(conjuncts, &is_nil/1))
  end

  @spec scope_summary(map()) :: String.t()
  def scope_summary(tracker_settings) when is_map(tracker_settings) do
    parts =
      [
        teams_summary(team_keys(tracker_settings)),
        cycle_summary(current_cycle?(tracker_settings)),
        project_summary(project_slug(tracker_settings)),
        labels_summary("any labels", label_list(tracker_settings, :any_labels)),
        labels_summary("required labels", label_list(tracker_settings, :required_labels))
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "n/a"
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc """
  The configured team keys, trimmed and deduplicated.

  Keys are not case-folded: they are matched with `eqIgnoreCase` at query time
  and reported back to the operator verbatim in errors and on the status board.
  """
  @spec team_keys(map()) :: [String.t()]
  def team_keys(tracker_settings) when is_map(tracker_settings) do
    tracker_settings
    |> provider_map()
    |> Map.get("team_keys")
    |> normalize_team_keys()
  end

  @spec current_cycle?(map()) :: boolean()
  def current_cycle?(tracker_settings) when is_map(tracker_settings) do
    Map.get(provider_map(tracker_settings), "current_cycle") == true
  end

  defp provider_map(tracker_settings) do
    case Map.get(tracker_settings, :provider) do
      provider when is_map(provider) -> provider
      _ -> %{}
    end
  end

  # `project_slug` is read from the typed field because `Config.Schema` mirrors the provider
  # value onto it, and every existing Linear call site already reads it there. It is trimmed
  # here, at the single point of access, so presence, the emitted `slugId` and the board text
  # can never disagree: a padded slug that counted as a scope but was queried verbatim would
  # match no project and return zero issues forever, with clean logs.
  defp project_slug(tracker_settings) do
    case Map.get(tracker_settings, :project_slug) do
      slug when is_binary(slug) -> String.trim(slug)
      _ -> nil
    end
  end

  defp label_list(tracker_settings, key) do
    case Map.get(tracker_settings, key) do
      labels when is_list(labels) -> labels
      _ -> []
    end
  end

  defp validate_team_keys_shape(provider) do
    case Map.get(provider, "team_keys") do
      nil -> :ok
      keys when is_list(keys) -> validate_team_key_entries(keys)
      _other -> {:error, :invalid_linear_team_keys}
    end
  end

  defp validate_team_key_entries(keys) do
    if Enum.all?(keys, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_linear_team_keys}
    end
  end

  defp validate_current_cycle_shape(provider) do
    case Map.get(provider, "current_cycle") do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _other -> {:error, :invalid_linear_current_cycle}
    end
  end

  # Counts contributed filter fragments, never present keys: `current_cycle: false` and an
  # injected `"project_slug" => nil` are both present-but-empty. Labels narrow a container,
  # they do not define one, so they are not counted here.
  defp validate_scope_present(tracker_settings) do
    scoped? =
      team_keys(tracker_settings) != [] or
        present_string?(project_slug(tracker_settings)) or
        current_cycle?(tracker_settings)

    if scoped?, do: :ok, else: {:error, :missing_linear_scope}
  end

  # An unqualified `cycle: {isActive: {eq: true}}` matches the active cycle of every team the
  # token can see, so the day a second team is added the instance would silently dispatch
  # agents against another team's tickets.
  defp validate_cycle_is_team_qualified(tracker_settings) do
    if current_cycle?(tracker_settings) and team_keys(tracker_settings) == [] do
      {:error, :missing_linear_team_keys}
    else
      :ok
    end
  end

  defp normalize_team_keys(keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_team_keys(_keys), do: []

  defp team_conjunct([]), do: nil
  defp team_conjunct(keys), do: %{or: Enum.map(keys, &%{team: %{key: %{eqIgnoreCase: &1}}})}

  defp project_conjunct(slug) do
    if present_string?(slug), do: %{project: %{slugId: %{eq: slug}}}, else: nil
  end

  defp any_labels_conjunct([]), do: nil
  defp any_labels_conjunct(labels), do: %{or: Enum.map(labels, &label_clause/1)}

  defp required_label_conjuncts(labels), do: Enum.map(labels, &label_clause/1)

  defp label_clause(label), do: %{labels: %{some: %{name: %{eqIgnoreCase: label}}}}

  defp maybe_put_state(filter, state_names) when is_list(state_names) and state_names != [] do
    Map.put(filter, :state, %{or: Enum.map(state_names, &%{name: %{eqIgnoreCase: &1}})})
  end

  defp maybe_put_state(filter, _state_names), do: filter

  defp maybe_put_cycle(filter, true), do: Map.put(filter, :cycle, %{isActive: %{eq: true}})
  defp maybe_put_cycle(filter, _current_cycle?), do: filter

  defp maybe_put_conjuncts(filter, []), do: filter
  defp maybe_put_conjuncts(filter, conjuncts), do: Map.put(filter, :and, conjuncts)

  defp teams_summary([]), do: nil
  defp teams_summary(keys), do: "teams " <> Enum.join(keys, ", ")

  defp cycle_summary(true), do: "current cycle"
  defp cycle_summary(_current_cycle?), do: nil

  defp project_summary(slug) do
    if present_string?(slug), do: "project " <> slug, else: nil
  end

  defp labels_summary(_label, []), do: nil
  defp labels_summary(label, labels), do: label <> " " <> Enum.join(labels, ", ")

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
