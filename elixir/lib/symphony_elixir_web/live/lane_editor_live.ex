# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule SymphonyElixirWeb.LaneEditorLive do
  @moduledoc "Structured lane editor with a lossless raw draft behind its controls."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias Phoenix.LiveView.JS
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Lanes
  alias SymphonyElixir.Lanes.Lane
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.{ConfigurationFields, ObservabilityPubSub}

  import ConfigurationFields, only: [profile_fields: 1]

  @config_fields [
    {"tracker_kind", ["tracker", "kind"], :text},
    {"tracker_endpoint", ["tracker", "endpoint"], :text},
    {"tracker_api_key", ["tracker", "api_key"], :text},
    {"tracker_project_slug", ["tracker", "project_slug"], :text},
    {"tracker_assignee", ["tracker", "assignee"], :text},
    {"tracker_required_labels", ["tracker", "required_labels"], :list},
    {"tracker_any_labels", ["tracker", "any_labels"], :list},
    {"tracker_active_states", ["tracker", "active_states"], :list},
    {"tracker_terminal_states", ["tracker", "terminal_states"], :list},
    {"tracker_provider_json", ["tracker", "provider"], :json},
    {"tracker_team_keys", ["tracker", "provider", "team_keys"], :list},
    {"tracker_current_cycle", ["tracker", "provider", "current_cycle"], :boolean},
    {"github_api_url", ["tracker", "provider", "api_url"], :text},
    {"github_token", ["tracker", "provider", "token"], :secret},
    {"github_repo", ["tracker", "provider", "repo"], :text},
    {"gitlab_api_url", ["tracker", "provider", "api_url"], :text},
    {"gitlab_api_key", ["tracker", "provider", "api_key"], :secret},
    {"gitlab_project_path", ["tracker", "provider", "project_path"], :text},
    {"jira_base_url", ["tracker", "provider", "base_url"], :text},
    {"jira_email", ["tracker", "provider", "email"], :text},
    {"jira_api_token", ["tracker", "provider", "api_token"], :secret},
    {"jira_project_key", ["tracker", "provider", "project_key"], :text},
    {"asana_endpoint", ["tracker", "provider", "endpoint"], :text},
    {"asana_api_key", ["tracker", "provider", "api_key"], :secret},
    {"asana_project_gid", ["tracker", "provider", "project_gid"], :text},
    {"polling_interval_ms", ["polling", "interval_ms"], :duration},
    {"agent_max_concurrent_agents", ["agent", "max_concurrent_agents"], :integer},
    {"agent_max_turns", ["agent", "max_turns"], :integer},
    {"agent_max_turn_exhaustions", ["agent", "max_turn_exhaustions"], :integer},
    {"agent_max_retry_backoff_ms", ["agent", "max_retry_backoff_ms"], :duration},
    {"agent_max_concurrent_agents_by_state_json", ["agent", "max_concurrent_agents_by_state"], :json},
    {"agent_backend", ["agent", "backend"], :text},
    {"agent_backend_by_state_json", ["agent", "backend_by_state"], :json},
    {"agent_blocked_state", ["agent", "blocked_state"], :text},
    {"agent_in_progress_state", ["agent", "in_progress_state"], :text},
    {"codex_command", ["codex", "command"], :text},
    {"codex_approval_policy_json", ["codex", "approval_policy"], :json},
    {"codex_thread_sandbox", ["codex", "thread_sandbox"], :text},
    {"codex_turn_sandbox_policy_json", ["codex", "turn_sandbox_policy"], :json},
    {"codex_turn_timeout_ms", ["codex", "turn_timeout_ms"], :duration},
    {"codex_read_timeout_ms", ["codex", "read_timeout_ms"], :duration},
    {"codex_stall_timeout_ms", ["codex", "stall_timeout_ms"], :duration},
    {"claude_command", ["claude", "command"], :text},
    {"claude_args", ["claude", "args"], :list},
    {"claude_linear_mcp_command", ["claude", "linear_mcp_command"], :text},
    {"claude_linear_mcp_args", ["claude", "linear_mcp_args"], :list},
    {"claude_allowed_tools", ["claude", "allowed_tools"], :list},
    {"claude_extra_mcp_servers_json", ["claude", "extra_mcp_servers"], :json},
    {"hooks_after_create", ["hooks", "after_create"], :text},
    {"hooks_before_run", ["hooks", "before_run"], :text},
    {"hooks_after_run", ["hooks", "after_run"], :text},
    {"hooks_before_remove", ["hooks", "before_remove"], :text},
    {"hooks_timeout_ms", ["hooks", "timeout_ms"], :duration},
    {"observability_dashboard_enabled", ["observability", "dashboard_enabled"], :boolean},
    {"observability_refresh_ms", ["observability", "refresh_ms"], :duration},
    {"observability_render_interval_ms", ["observability", "render_interval_ms"], :duration}
  ]
  @tracker_provider_keys for {_field, ["tracker", "provider", key], _type} <- @config_fields, do: key

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe_lane(slug)
      :ok = ObservabilityPubSub.subscribe_profiles()
    end

    case Lanes.get_by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "No lane with slug #{slug}") |> push_navigate(to: "/")}

      lane ->
        version = Lanes.current_version(lane)
        config = lane_config(version)
        {:ok, assign_editor(socket, lane, lane_params(lane, version, config), config)}
    end
  end

  def mount(_params, _session, socket) do
    profiles = ExecutionProfiles.list()
    profile = List.first(profiles)
    config = Schema.lane_defaults()
    params = lane_params(nil, nil, config) |> Map.put("execution_profile_id", profile && profile.id)

    {:ok,
     assign(socket,
       lane: nil,
       params: params,
       original_config: config,
       profiles: profiles,
       errors: [],
       warnings: [],
       profile_create: nil
     )}
  end

  @impl true
  def handle_event(event, payload, socket) when event in ["validate", "save"] do
    incoming = if is_map(payload), do: Map.get(payload, "lane")
    {params, input_errors} = merge_params(socket.assigns.params, incoming)
    {config_result, validation_errors, warnings} = validate(socket.assigns.lane, params, socket.assigns.original_config)
    errors = input_errors ++ validation_errors

    result =
      if event == "save" and errors == [] do
        with {:ok, config} <- config_result,
             {:ok, attrs} <- canonical_params(params, config),
             attrs <- if(socket.assigns.lane, do: Map.delete(attrs, "slug"), else: attrs) do
          save_lane(socket.assigns.lane, attrs)
        end
      else
        {:error, errors}
      end

    case result do
      {:ok, lane} -> {:noreply, push_navigate(socket, to: "/lanes/#{lane.slug}")}
      {:error, save_errors} -> {:noreply, assign(socket, params: params, errors: save_errors, warnings: warnings)}
    end
  end

  def handle_event("open_profile_create", _payload, socket), do: {:noreply, assign(socket, :profile_create, profile_create_assigns())}
  def handle_event("cancel_profile_create", _payload, socket), do: {:noreply, assign(socket, :profile_create, nil)}

  def handle_event(event, %{"profile" => incoming}, socket) when event in ["validate_profile_create", "create_profile"] do
    panel = socket.assigns.profile_create || profile_create_assigns()
    params = Map.merge(panel.params, Map.take(incoming, Map.keys(panel.params)))
    {attrs, errors} = ConfigurationFields.profile_attributes(params, panel.original_worker)
    errors = errors ++ profile_errors(attrs)

    if event == "create_profile" and errors == [] do
      case ExecutionProfiles.create(attrs) do
        {:ok, profile} ->
          {:noreply,
           socket
           |> assign(:profiles, ExecutionProfiles.list())
           |> assign(:params, Map.put(socket.assigns.params, "execution_profile_id", profile.id))
           |> assign(:profile_create, nil)
           |> put_flash(:info, "Execution profile created and selected")}

        {:error, save_errors} ->
          {:noreply, assign(socket, profile_create: %{panel | params: params, errors: save_errors})}
      end
    else
      {:noreply, assign(socket, profile_create: %{panel | params: params, errors: errors})}
    end
  end

  def handle_event(event, _payload, socket) when event in ["validate_profile_create", "create_profile"] do
    panel = socket.assigns.profile_create || profile_create_assigns()
    {:noreply, assign(socket, profile_create: %{panel | errors: [%{path: "profile", message: "must be an object"}]})}
  end

  @impl true
  def handle_info({:lane_updated, slug}, socket) do
    if is_nil(Lanes.get_by_slug(slug)),
      do: {:noreply, socket |> put_flash(:error, "Lane no longer exists") |> push_navigate(to: "/")},
      else: {:noreply, socket}
  end

  def handle_info(:profiles_updated, socket), do: {:noreply, assign(socket, :profiles, ExecutionProfiles.list())}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <p class="eyebrow">{if @lane, do: "Edit lane", else: "New lane"}</p>
        <h1 class="hero-title">{if @lane, do: @lane.name, else: "New lane"}</h1>
        <p class="hero-copy">Create stays disabled until you explicitly enable the lane from the lane list.</p>
      </header>

      <section :if={@profile_create} class="section-card inline-panel" id="profile-create-panel">
        <div class="section-header"><div><h2 class="section-title">Create execution profile</h2><p class="section-copy">The lane draft stays here and the new profile will be selected after save.</p></div></div>
        <form id="profile-create-form" phx-change="validate_profile_create" phx-submit="create_profile" class="config-form">
          <ul :if={@profile_create.errors != []} id="profile-create-errors" class="error-summary" role="alert"><li :for={error <- @profile_create.errors}>{error.path}: {error.message}</li></ul>
          <fieldset class="form-section">
            <legend>Profile identity</legend>
            <label for="inline-profile-name">Name</label><input id="inline-profile-name" type="text" name="profile[name]" value={@profile_create.params["name"]} autofocus />
            <label for="inline-profile-description">Description</label><textarea id="inline-profile-description" name="profile[description]" rows="2">{@profile_create.params["description"]}</textarea>
            <label for="inline-profile-workspace-base">Workspace base directory</label><input id="inline-profile-workspace-base" type="text" name="profile[workspace_base]" value={@profile_create.params["workspace_base"]} />
          </fieldset>
          <.profile_fields params={@profile_create.params} errors={@profile_create.errors} />
          <div class="form-actions"><button type="submit">Create profile</button><button type="button" class="issue-link" phx-click={JS.push("cancel_profile_create") |> JS.focus(to: "#profile-select")}>Cancel</button></div>
        </form>
      </section>

      <form id="lane-form" phx-change="validate" phx-submit="save" class="section-card lane-form">
        <ul :if={@errors != []} id="lane-errors" class="error-summary" role="alert"><li :for={error <- @errors}>{error.path}: {error.message}</li></ul>
        <ul :if={@warnings != []} id="lane-warnings" class="muted" role="status"><li :for={warning <- @warnings}>{warning}</li></ul>

        <fieldset class="form-section" id="work-selection">
          <legend>Work selection</legend>
          <label for="lane-name">Name</label><input id="lane-name" type="text" name="lane[name]" value={@params["name"]} autofocus={is_nil(@lane)} />
          <.lane_field_errors errors={@errors} field="name" path="name" />
          <label for="lane-slug">Slug {if @lane, do: "(immutable after creation)", else: "(used as the default workspace subdirectory)"}</label><input id="lane-slug" type="text" name="lane[slug]" value={@params["slug"]} readonly={not is_nil(@lane)} />
          <.lane_field_errors errors={@errors} field="slug" path="slug" />
          <label for="tracker-kind">Tracker adapter</label><select id="tracker-kind" name="lane[tracker_kind]"><option :for={kind <- Tracker.kinds()} value={kind} selected={@params["tracker_kind"] == kind}>{kind}</option></select>
          <.lane_field_errors errors={@errors} field="tracker_kind" path="tracker.kind" />

          <div :if={@params["tracker_kind"] == "linear"} class="config-subsection">
            <label for="tracker-endpoint">Linear endpoint</label><input id="tracker-endpoint" type="url" name="lane[tracker_endpoint]" value={@params["tracker_endpoint"]} />
            <label for="tracker-api-key">API key reference</label><input id="tracker-api-key" type="text" name="lane[tracker_api_key]" value={@params["tracker_api_key"]} autocomplete="off" />
            <label for="tracker-project-slug">Project slug</label><input id="tracker-project-slug" type="text" name="lane[tracker_project_slug]" value={@params["tracker_project_slug"]} />
            <label for="tracker-assignee">Assignee reference</label><input id="tracker-assignee" type="text" name="lane[tracker_assignee]" value={@params["tracker_assignee"]} />
            <label for="tracker-team-keys">Team keys (one per line)</label><textarea id="tracker-team-keys" name="lane[tracker_team_keys]" rows="3">{@params["tracker_team_keys"]}</textarea>
            <input type="hidden" name="lane[tracker_current_cycle]" value="false" />
            <label for="tracker-current-cycle"><input id="tracker-current-cycle" type="checkbox" name="lane[tracker_current_cycle]" value="true" checked={truthy?(@params["tracker_current_cycle"])} /> Current cycle only</label>
          </div>

          <div :if={@params["tracker_kind"] == "github"} class="config-subsection">
            <label for="github-api-url">GitHub API URL</label><input id="github-api-url" type="url" name="lane[github_api_url]" value={@params["github_api_url"]} />
            <label for="github-token">Token reference</label><input id="github-token" type="text" name="lane[github_token]" value={@params["github_token"]} autocomplete="off" />
            <label for="github-repo">Repository (owner/name)</label><input id="github-repo" type="text" name="lane[github_repo]" value={@params["github_repo"]} />
          </div>

          <div :if={@params["tracker_kind"] == "gitlab"} class="config-subsection">
            <label for="gitlab-api-url">GitLab API URL</label><input id="gitlab-api-url" type="url" name="lane[gitlab_api_url]" value={@params["gitlab_api_url"]} />
            <label for="gitlab-api-key">API key reference</label><input id="gitlab-api-key" type="text" name="lane[gitlab_api_key]" value={@params["gitlab_api_key"]} autocomplete="off" />
            <label for="gitlab-project-path">Project path</label><input id="gitlab-project-path" type="text" name="lane[gitlab_project_path]" value={@params["gitlab_project_path"]} />
          </div>

          <div :if={@params["tracker_kind"] == "jira"} class="config-subsection">
            <label for="jira-base-url">Jira base URL</label><input id="jira-base-url" type="url" name="lane[jira_base_url]" value={@params["jira_base_url"]} />
            <label for="jira-email">Account email</label><input id="jira-email" type="email" name="lane[jira_email]" value={@params["jira_email"]} />
            <label for="jira-api-token">API token reference</label><input id="jira-api-token" type="text" name="lane[jira_api_token]" value={@params["jira_api_token"]} autocomplete="off" />
            <label for="jira-project-key">Project key</label><input id="jira-project-key" type="text" name="lane[jira_project_key]" value={@params["jira_project_key"]} />
          </div>

          <div :if={@params["tracker_kind"] == "asana"} class="config-subsection">
            <label for="asana-endpoint">Asana endpoint</label><input id="asana-endpoint" type="url" name="lane[asana_endpoint]" value={@params["asana_endpoint"]} />
            <label for="asana-api-key">API key reference</label><input id="asana-api-key" type="text" name="lane[asana_api_key]" value={@params["asana_api_key"]} autocomplete="off" />
            <label for="asana-project-gid">Project GID</label><input id="asana-project-gid" type="text" name="lane[asana_project_gid]" value={@params["asana_project_gid"]} />
          </div>
          <.lane_field_errors errors={@errors} field="tracker_provider" path="tracker.provider" />
          <label for="tracker-required-labels">Required labels (one per line)</label><textarea id="tracker-required-labels" name="lane[tracker_required_labels]" rows="3">{@params["tracker_required_labels"]}</textarea>
          <label for="tracker-any-labels">Any labels (one per line)</label><textarea id="tracker-any-labels" name="lane[tracker_any_labels]" rows="3">{@params["tracker_any_labels"]}</textarea>
          <label for="tracker-active-states">Active states (one per line)</label><textarea id="tracker-active-states" name="lane[tracker_active_states]" rows="3">{@params["tracker_active_states"]}</textarea>
          <label for="tracker-terminal-states">Terminal states (one per line)</label><textarea id="tracker-terminal-states" name="lane[tracker_terminal_states]" rows="3">{@params["tracker_terminal_states"]}</textarea>
          <details><summary>Uncommon adapter settings</summary><label for="tracker-provider">Additional tracker settings (JSON)</label><textarea id="tracker-provider" name="lane[tracker_provider_json]" rows="5" class="mono">{@params["tracker_provider_json"]}</textarea></details>
        </fieldset>

        <fieldset class="form-section" id="execution">
          <legend>Execution</legend>
          <label for="profile-select">Execution profile</label><select id="profile-select" name="lane[execution_profile_id]"><option value="">Choose a profile</option><option :for={profile <- @profiles} value={profile.id} selected={to_string(profile.id) == to_string(@params["execution_profile_id"])}>{profile.name}</option></select>
          <.lane_field_errors errors={@errors} field="execution_profile_id" path="execution_profile_id" />
          <button type="button" class="subtle-button" phx-click="open_profile_create">Create profile inline</button>
          <p :if={selected_profile(@profiles, @params["execution_profile_id"])} class="field-help"><a class="issue-link" href={"/execution-profiles/#{selected_profile(@profiles, @params["execution_profile_id"]).id}"}>View selected profile</a> · {profile_summary(selected_profile(@profiles, @params["execution_profile_id"]))}</p>
          <p :if={selected_profile(@profiles, @params["execution_profile_id"])} class="field-help">Effective workspace: <span class="mono">{effective_workspace(selected_profile(@profiles, @params["execution_profile_id"]), @params["workspace_subdir"])}</span></p>
          <p :if={@profiles == []} class="empty-state">No execution profiles exist. Create one to continue.</p>
          <label for="lane-workspace-subdir">Advanced workspace subdirectory</label><input id="lane-workspace-subdir" type="text" name="lane[workspace_subdir]" value={@params["workspace_subdir"]} />
          <.lane_field_errors errors={@errors} field="workspace_subdir" path="workspace_subdir" />
        </fieldset>

        <fieldset class="form-section" id="workflow">
          <legend>Workflow</legend>
          <label for="lane-prompt">Prompt</label><textarea id="lane-prompt" name="lane[prompt]" rows="8" phx-debounce="300">{@params["prompt"]}</textarea>
          <label for="agent-backend">Agent backend</label><select id="agent-backend" name="lane[agent_backend]"><option value="codex" selected={@params["agent_backend"] == "codex"}>Codex</option><option value="claude" selected={@params["agent_backend"] == "claude"}>Claude</option></select>
          <label for="agent-backend-by-state">Backend overrides by state (JSON)</label><textarea id="agent-backend-by-state" name="lane[agent_backend_by_state_json]" rows="3" class="mono">{@params["agent_backend_by_state_json"]}</textarea>
          <label for="agent-blocked-state">Blocked state</label><input id="agent-blocked-state" type="text" name="lane[agent_blocked_state]" value={@params["agent_blocked_state"]} />
          <label for="agent-in-progress-state">In-progress state</label><input id="agent-in-progress-state" type="text" name="lane[agent_in_progress_state]" value={@params["agent_in_progress_state"]} />

          <div :if={@params["agent_backend"] == "codex"} class="config-subsection">
            <h3>Codex settings</h3>
            <label for="codex-command">Command</label><input id="codex-command" type="text" name="lane[codex_command]" value={@params["codex_command"]} />
            <label for="codex-approval-policy">Approval policy (JSON)</label><textarea id="codex-approval-policy" name="lane[codex_approval_policy_json]" rows="5" class="mono">{@params["codex_approval_policy_json"]}</textarea>
            <label for="codex-thread-sandbox">Thread sandbox</label><input id="codex-thread-sandbox" type="text" name="lane[codex_thread_sandbox]" value={@params["codex_thread_sandbox"]} />
            <label for="codex-turn-sandbox-policy">Turn sandbox policy (JSON)</label><textarea id="codex-turn-sandbox-policy" name="lane[codex_turn_sandbox_policy_json]" rows="5" class="mono">{@params["codex_turn_sandbox_policy_json"]}</textarea>
            <label for="codex-turn-timeout">Turn timeout (seconds)</label><input id="codex-turn-timeout" type="text" inputmode="decimal" name="lane[codex_turn_timeout_ms]" value={@params["codex_turn_timeout_ms"]} />
            <label for="codex-read-timeout">Read timeout (seconds)</label><input id="codex-read-timeout" type="text" inputmode="decimal" name="lane[codex_read_timeout_ms]" value={@params["codex_read_timeout_ms"]} />
            <label for="codex-stall-timeout">Stall timeout (seconds)</label><input id="codex-stall-timeout" type="text" inputmode="decimal" name="lane[codex_stall_timeout_ms]" value={@params["codex_stall_timeout_ms"]} />
            <.lane_prefix_errors errors={@errors} prefix="codex." />
          </div>

          <div :if={@params["agent_backend"] == "claude"} class="config-subsection">
            <h3>Claude settings</h3>
            <label for="claude-command">Command</label><input id="claude-command" type="text" name="lane[claude_command]" value={@params["claude_command"]} />
            <label for="claude-args">Arguments (one per line)</label><textarea id="claude-args" name="lane[claude_args]" rows="3">{@params["claude_args"]}</textarea>
            <label for="claude-linear-mcp-command">Linear MCP command</label><input id="claude-linear-mcp-command" type="text" name="lane[claude_linear_mcp_command]" value={@params["claude_linear_mcp_command"]} />
            <label for="claude-linear-mcp-args">Linear MCP arguments (one per line)</label><textarea id="claude-linear-mcp-args" name="lane[claude_linear_mcp_args]" rows="3">{@params["claude_linear_mcp_args"]}</textarea>
            <label for="claude-allowed-tools">Allowed tools (one per line)</label><textarea id="claude-allowed-tools" name="lane[claude_allowed_tools]" rows="3">{@params["claude_allowed_tools"]}</textarea>
            <label for="claude-extra-mcp">Additional MCP servers (JSON)</label><textarea id="claude-extra-mcp" name="lane[claude_extra_mcp_servers_json]" rows="5" class="mono">{@params["claude_extra_mcp_servers_json"]}</textarea>
            <.lane_prefix_errors errors={@errors} prefix="claude." />
          </div>
          <label for="hooks-after-create">After-create setup hook</label><textarea id="hooks-after-create" name="lane[hooks_after_create]" rows="2">{@params["hooks_after_create"]}</textarea>
          <label for="hooks-before-run">Before-run hook</label><textarea id="hooks-before-run" name="lane[hooks_before_run]" rows="2">{@params["hooks_before_run"]}</textarea>
          <label for="hooks-after-run">After-run hook</label><textarea id="hooks-after-run" name="lane[hooks_after_run]" rows="2">{@params["hooks_after_run"]}</textarea>
          <label for="hooks-before-remove">Before-remove hook</label><textarea id="hooks-before-remove" name="lane[hooks_before_remove]" rows="2">{@params["hooks_before_remove"]}</textarea>
          <label for="hooks-timeout-ms">Hook timeout (seconds)</label><input id="hooks-timeout-ms" type="text" inputmode="decimal" name="lane[hooks_timeout_ms]" value={@params["hooks_timeout_ms"]} />
          <.lane_field_errors errors={@errors} field="hooks_timeout_ms" path="hooks.timeout_ms" />
        </fieldset>

        <fieldset class="form-section" id="limits">
          <legend>Limits</legend>
          <label for="polling-interval-ms">Polling interval (seconds)</label><input id="polling-interval-ms" type="text" inputmode="decimal" name="lane[polling_interval_ms]" value={@params["polling_interval_ms"]} />
          <.lane_field_errors errors={@errors} field="polling_interval_ms" path="polling.interval_ms" />
          <label for="max-concurrent-agents">Concurrent agents</label><input id="max-concurrent-agents" type="number" name="lane[agent_max_concurrent_agents]" value={@params["agent_max_concurrent_agents"]} />
          <label for="max-turns">Maximum turns</label><input id="max-turns" type="number" name="lane[agent_max_turns]" value={@params["agent_max_turns"]} />
          <label for="max-turn-exhaustions">Maximum turn exhaustions</label><input id="max-turn-exhaustions" type="number" name="lane[agent_max_turn_exhaustions]" value={@params["agent_max_turn_exhaustions"]} />
          <label for="retry-backoff-ms">Retry backoff (seconds)</label><input id="retry-backoff-ms" type="text" inputmode="decimal" name="lane[agent_max_retry_backoff_ms]" value={@params["agent_max_retry_backoff_ms"]} />
          <label for="state-limits">Per-state concurrency limits (JSON)</label><textarea id="state-limits" name="lane[agent_max_concurrent_agents_by_state_json]" rows="4" class="mono">{@params["agent_max_concurrent_agents_by_state_json"]}</textarea>
          <.lane_prefix_errors errors={@errors} prefix="agent." />
          <input type="hidden" name="lane[observability_dashboard_enabled]" value="false" />
          <label for="observability-dashboard-enabled"><input id="observability-dashboard-enabled" type="checkbox" name="lane[observability_dashboard_enabled]" value="true" checked={truthy?(@params["observability_dashboard_enabled"])} /> Dashboard enabled</label>
          <label for="observability-refresh-ms">Observability refresh (seconds)</label><input id="observability-refresh-ms" type="text" inputmode="decimal" name="lane[observability_refresh_ms]" value={@params["observability_refresh_ms"]} />
          <label for="observability-render-interval-ms">Render interval (seconds)</label><input id="observability-render-interval-ms" type="text" inputmode="decimal" name="lane[observability_render_interval_ms]" value={@params["observability_render_interval_ms"]} />
          <.lane_prefix_errors errors={@errors} prefix="observability." />
        </fieldset>

        <fieldset class="form-section" id="advanced-configuration">
          <legend>Advanced structured configuration</legend>
          <p class="field-help">Uncommon and imported fields stay in this structured object. Named controls patch this object without dropping unknown keys.</p>
          <label for="advanced-json">Advanced configuration (JSON object)</label><textarea id="advanced-json" name="lane[advanced_json]" rows="18" class="mono" phx-debounce="300">{@params["advanced_json"]}</textarea>
        </fieldset>

        <fieldset :if={@lane} class="form-section"><legend>History</legend><label for="lane-note">Change note</label><input id="lane-note" type="text" name="lane[note]" value={@params["note"]} /></fieldset>
        <div class="form-actions"><button type="submit" disabled={@profiles == []}>Save lane</button><a class="issue-link" href={if @lane, do: "/lanes/#{@lane.slug}", else: "/"}>Cancel</a></div>
      </form>
    </section>
    """
  end

  defp assign_editor(socket, lane, params, config),
    do: assign(socket, lane: lane, params: params, original_config: config, profiles: ExecutionProfiles.list(), errors: [], warnings: config_warnings(config), profile_create: nil)

  defp save_lane(nil, params), do: Lanes.create(params)

  defp save_lane(%Lane{slug: slug}, params) do
    case Lanes.get_by_slug(slug) do
      nil -> {:error, [%{path: "lane", message: "Lane no longer exists"}]}
      lane -> Lanes.update(lane, params)
    end
  end

  defp merge_params(params, incoming) when is_map(incoming) do
    submitted_fields = incoming |> Map.keys() |> MapSet.new()

    {params, errors} =
      Enum.reduce(Map.take(incoming, Map.keys(params)), {params, []}, fn {field, value}, {params, errors} ->
        if is_binary(value) or is_boolean(value) or is_integer(value), do: {Map.put(params, field, value), errors}, else: {params, [%{path: field, message: "must be a scalar form value"} | errors]}
      end)

    params =
      params
      |> Map.put("_submitted_fields", submitted_fields)
      |> then(&if(&1["workspace_subdir"] in [nil, ""], do: Map.put(&1, "workspace_subdir", &1["slug"]), else: &1))

    {params, errors}
  end

  defp merge_params(params, _incoming), do: {params, [%{path: "lane", message: "must be an object"}]}

  defp validate(lane, params, original_config) do
    config_result = config_from_params(params, original_config)
    params = Map.put(params, "workspace_subdir", workspace_subdir(params))

    lane_errors =
      (lane || %Lane{})
      |> Lane.changeset(Map.take(params, ~w(slug name enabled execution_profile_id workspace_subdir)))
      |> Ecto.Changeset.traverse_errors(fn {message, opts} -> Enum.reduce(opts, message, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end) end)
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &%{path: to_string(field), message: &1}) end)

    errors =
      case config_result do
        {:ok, config} -> lane_errors ++ validate_against_profile(params, config)
        {:error, errors} -> lane_errors ++ errors
      end

    warnings =
      case config_result do
        {:ok, config} -> config_warnings(config)
        _ -> []
      end

    {config_result, errors, warnings}
  end

  defp validate_against_profile(params, config) do
    case integer_param(params["execution_profile_id"]) do
      {:ok, id} ->
        case ExecutionProfiles.get(id) do
          nil ->
            [%{path: "execution_profile_id", message: "not found"}]

          profile ->
            errors_for_resolution(
              Configuration.resolve(
                profile_attrs(profile),
                config,
                workspace_subdir(params),
                params["prompt"]
              )
            )
        end

      {:error, errors} ->
        errors
    end
  end

  defp errors_for_resolution({:ok, _}), do: []
  defp errors_for_resolution({:error, errors}), do: errors

  defp canonical_params(params, config) do
    with {:ok, profile_id} <- integer_param(params["execution_profile_id"]) do
      {:ok,
       params
       |> Map.merge(%{"config" => config, "execution_profile_id" => profile_id, "workspace_subdir" => workspace_subdir(params)})
       |> Map.drop(["_submitted_fields", "enabled" | config_param_keys()])}
    end
  end

  defp config_from_params(params, original_config) do
    with {:ok, advanced} <- decode_json(params["advanced_json"], "advanced", advanced_config(original_config)),
         base = deep_merge(known_config(original_config), advanced),
         {config, errors} <- patch_config(base, params, original_config) do
      if errors == [], do: {:ok, config}, else: {:error, errors}
    end
  end

  defp patch_config(config, params, original_config) do
    submitted_fields = Map.get(params, "_submitted_fields", MapSet.new())

    Enum.reduce(@config_fields, {config, []}, fn {field, path, type}, {config, errors} ->
      case if(MapSet.member?(submitted_fields, field), do: parse_value(params[field], type, field, get_in(original_config, path)), else: :keep) do
        :keep -> {config, errors}
        {:ok, value} -> {put_or_delete(config, path, value), errors}
        {:error, error} -> {config, [error | errors]}
      end
    end)
  end

  defp parse_value(value, :text, _field, original) do
    cond do
      value == "$REDACTED" -> {:ok, original}
      is_binary(value) and String.trim(value) == "" -> {:ok, nil}
      is_binary(value) -> {:ok, value}
      true -> {:error, %{path: "config", message: "must be a string"}}
    end
  end

  defp parse_value(value, :secret, field, original), do: parse_value(value, :text, field, original)

  defp parse_value(value, :list, _field, original) when value == "$REDACTED", do: {:ok, original}
  defp parse_value(value, :list, _field, _original) when is_binary(value), do: {:ok, String.split(value, ~r/[\r\n]+/, trim: true)}
  defp parse_value(value, :integer, _field, original) when value == "$REDACTED", do: {:ok, original}
  defp parse_value(value, :integer, _field, _original) when value in [nil, ""], do: {:ok, nil}
  defp parse_value(value, :integer, _field, _original) when is_integer(value), do: {:ok, value}

  defp parse_value(value, :integer, field, _original) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, %{path: field, message: "must be an integer"}}
    end
  end

  defp parse_value(value, :duration, _field, original) when value == "$REDACTED", do: {:ok, original}
  defp parse_value(value, :duration, _field, _original) when value in [nil, ""], do: {:ok, nil}
  defp parse_value(value, :duration, field, _original), do: ConfigurationFields.parse_duration(value, config_path(field))

  defp parse_value(value, :boolean, _field, _original) when value in [true, "true", "on"], do: {:ok, true}
  defp parse_value(value, :boolean, _field, _original) when value in [false, "false", ""], do: {:ok, false}
  defp parse_value(_value, :boolean, field, _original), do: {:error, %{path: field, message: "must be a boolean"}}
  defp parse_value(value, :json, field, original), do: decode_json(value, field, original)

  defp decode_json(value, _field, _original) when is_map(value), do: {:ok, value}

  defp decode_json(value, field, original) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, value} when field != "advanced" -> {:ok, restore_redacted(value, original)}
      {:ok, map} when is_map(map) -> {:ok, restore_redacted(map, original)}
      {:ok, _} -> {:error, [%{path: field, message: "must be a JSON object"}]}
      {:error, reason} -> {:error, [%{path: field, message: "invalid JSON: #{Exception.message(reason)}"}]}
    end
  end

  defp decode_json(_value, field, _original), do: {:error, [%{path: field, message: "must be a JSON object"}]}
  defp restore_redacted(value, original) when value == "$REDACTED", do: original
  defp restore_redacted(map, original) when is_map(map), do: Map.new(map, fn {key, child} -> {key, restore_redacted(child, Map.get(original || %{}, key))} end)
  defp restore_redacted(value, _original), do: value
  defp put_or_delete(config, path, value) when value in [nil, "", []], do: delete_path(config, path)
  defp put_or_delete(config, [key], value), do: Map.put(config, key, value)
  defp put_or_delete(config, [key | rest], value), do: Map.put(config, key, put_or_delete(Map.get(config, key) || %{}, rest, value))
  defp delete_path(config, [key]), do: Map.delete(config, key)

  defp delete_path(config, [key | rest]) do
    case Map.get(config, key) do
      child when is_map(child) ->
        child = delete_path(child, rest)
        if child == %{}, do: Map.delete(config, key), else: Map.put(config, key, child)

      _ ->
        config
    end
  end

  defp lane_params(lane, version, config) do
    params = %{
      "slug" => lane && lane.slug,
      "name" => (lane && lane.name) || "",
      "enabled" => (lane && lane.enabled) || false,
      "execution_profile_id" => lane && lane.execution_profile_id,
      "workspace_subdir" => (lane && lane.workspace_subdir) || (lane && lane.slug) || "",
      "prompt" => (version && version.prompt) || "",
      "note" => "",
      "advanced_json" => config |> advanced_config() |> ConfigurationFields.safe_json()
    }

    Enum.reduce(@config_fields, params, fn {field, path, type}, acc -> Map.put(acc, field, field_value(config, path, type)) end)
  end

  defp field_value(config, path, :list), do: config |> get_in(path) |> List.wrap() |> Enum.join("\n")

  defp field_value(config, ["tracker", "provider"], :json) do
    config
    |> get_in(["tracker", "provider"])
    |> then(&Map.drop(&1 || %{}, @tracker_provider_keys))
    |> ConfigurationFields.safe_json()
  end

  defp field_value(config, path, :json), do: ConfigurationFields.safe_json(get_in(config, path) || %{})
  defp field_value(config, path, :boolean), do: get_in(config, path) in [true, "true"]
  defp field_value(config, path, :duration), do: ConfigurationFields.duration_input(get_in(config, path))

  defp field_value(config, path, :secret) do
    case get_in(config, path) do
      value when is_binary(value) -> if(String.starts_with?(value, "$"), do: value, else: "$REDACTED")
      _ -> ""
    end
  end

  defp field_value(config, ["tracker", "api_key"], :text) do
    case get_in(config, ["tracker", "api_key"]) do
      value when is_binary(value) -> if(String.starts_with?(value, "$"), do: value, else: "$REDACTED")
      _ -> ""
    end
  end

  defp field_value(config, path, _type), do: value_string(get_in(config, path))
  defp lane_config(nil), do: %{}

  defp lane_config(version) do
    case Workflow.parse_parts(version.front_matter, "") do
      {:ok, %{config: raw}} ->
        {_profile, config} = Configuration.split(raw)
        config

      _ ->
        %{}
    end
  end

  defp profile_create_assigns do
    params = %{
      "name" => "",
      "description" => "",
      "workspace_base" => Path.join(System.tmp_dir!(), "symphony_workspaces"),
      "worker_mode" => "local",
      "ssh_hosts" => "",
      "max_concurrent_agents_per_host" => "",
      "environment_kind" => "",
      "deployment_id" => "",
      "startup_timeout" => "",
      "shutdown_timeout" => "",
      "terminal_retention" => "",
      "provider_json" => "{}"
    }

    %{params: params, errors: [], original_worker: %{}}
  end

  defp profile_errors(attrs) do
    case Configuration.validate_profile(attrs) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp profile_attrs(profile), do: %{"name" => profile.name, "description" => profile.description, "workspace_base" => profile.workspace_base, "worker" => profile.worker}
  defp selected_profile(profiles, id), do: Enum.find(profiles, &(&1.id == id or to_string(&1.id) == to_string(id)))
  defp profile_summary(profile), do: "#{profile.name} · #{worker_label(profile.worker)}"
  defp worker_label(worker) when is_map(worker), do: if(is_map(worker["environment"]), do: "managed", else: if(worker["ssh_hosts"] in [nil, []], do: "local", else: "static SSH"))
  defp worker_label(_), do: "unknown"
  defp effective_workspace(nil, _subdir), do: "unavailable"
  defp effective_workspace(profile, subdir), do: Path.join(profile.workspace_base || "", subdir || "")
  defp integer_param(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, [%{path: "execution_profile_id", message: "must be an integer"}]}
    end
  end

  defp integer_param(_), do: {:error, [%{path: "execution_profile_id", message: "must be an integer"}]}
  defp config_warnings(config) when is_map(config), do: if(Map.has_key?(config, "server"), do: ["server is configured per installation and is preserved only in advanced configuration"], else: [])
  defp config_warnings(_), do: []
  defp value_string(nil), do: ""
  defp value_string(value), do: to_string(value)
  defp truthy?(value), do: value in [true, "true", "on"]
  defp config_param_keys, do: Enum.map(@config_fields, &elem(&1, 0)) ++ ["advanced_json"]

  defp config_path(field) do
    case Enum.find(@config_fields, &(elem(&1, 0) == field)) do
      {_field, path, _type} -> Enum.join(path, ".")
      nil -> field
    end
  end

  defp known_config(config) do
    Enum.reduce(@config_fields, %{}, fn {_field, path, _type}, known ->
      case get_in(config, path) do
        nil -> known
        value -> put_or_delete(known, path, value)
      end
    end)
  end

  defp advanced_config(config), do: Enum.reduce(@config_fields, config, fn {_field, path, _type}, advanced -> delete_path(advanced, path) end)

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value), do: deep_merge(left_value, right_value), else: right_value
    end)
  end

  defp lane_field_errors(assigns) do
    matching_errors = Enum.filter(assigns.errors, &(&1.path in [assigns.field, assigns.path, "config." <> assigns.path]))
    assigns = assign(assigns, :matching_errors, matching_errors)

    ~H"""
    <p :for={error <- @matching_errors} class="field-error" role="alert">{error.message}</p>
    """
  end

  defp lane_prefix_errors(assigns) do
    matching_errors = Enum.filter(assigns.errors, &(String.starts_with?(&1.path, assigns.prefix) or String.starts_with?(&1.path, "config." <> assigns.prefix)))
    assigns = assign(assigns, :matching_errors, matching_errors)

    ~H"""
    <p :for={error <- @matching_errors} class="field-error" role="alert">{error.path}: {error.message}</p>
    """
  end

  defp workspace_subdir(params), do: if(params["workspace_subdir"] in [nil, ""], do: params["slug"] || "", else: params["workspace_subdir"])
end
