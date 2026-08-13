defmodule AgentCodingBenchWeb.TaskHistoryLive do
  use AgentCodingBenchWeb, :live_view

  alias AgentCodingBench.World

  @impl true
  def mount(_params, _session, socket) do
    options = World.task_filter_options()

    {:ok,
     socket
     |> assign(:page_title, "Task history")
     |> assign(:task_count, 0)
     |> assign(:filter_form, to_form(empty_filters(), as: :filters))
     |> assign(:lane_options, lane_options(options.lanes))
     |> assign(:repo_options, repo_options(options.world_repos))
     |> stream(:tasks, [], dom_id: &"task-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from_params(params)
    tasks = World.list_tasks(filters)

    {:noreply,
     socket
     |> assign(:task_count, length(tasks))
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> stream(:tasks, tasks, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks?#{filters_from_params(filters)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="task-history-page" class={["mx-auto w-full max-w-7xl px-5 py-8 sm:px-8 lg:py-12"]}>
        <header class={["mb-8 flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between"]}>
          <div class={["max-w-2xl"]}>
            <div class={["mb-3 flex items-center gap-3"]}>
              <span class={["h-px w-8 bg-cyan-400/70"]}></span>
              <span class={[
                "font-mono text-[0.68rem] font-semibold uppercase tracking-[0.28em] text-cyan-300"
              ]}>
                Operational record
              </span>
            </div>
            <h1 class={["text-3xl font-semibold tracking-[-0.04em] text-slate-50 sm:text-4xl"]}>
              Task history
            </h1>
            <p class={["mt-3 max-w-xl text-sm leading-6 text-slate-400 sm:text-base"]}>
              Trace each Lane’s work from invention through merge or mechanical abandonment.
            </p>
          </div>

          <.link
            navigate={~p"/"}
            id="world-page-link"
            class={[
              "inline-flex w-fit items-center gap-2 rounded-xl border border-slate-700 bg-slate-900 px-4 py-2.5 text-sm font-semibold text-slate-200 transition hover:-translate-y-0.5 hover:border-cyan-300/30 hover:text-cyan-200"
            ]}
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to World
          </.link>
        </header>

        <.form
          for={@filter_form}
          id="task-filters"
          phx-change="filter"
          class={[
            "mb-5 grid gap-4 rounded-2xl border border-slate-800 bg-slate-900/75 p-5 shadow-xl shadow-black/10 sm:grid-cols-3"
          ]}
        >
          <.input
            field={@filter_form[:lane]}
            type="select"
            label="Lane"
            options={@lane_options}
            class={[
              "mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-3 py-2.5 text-sm text-slate-100 outline-none transition hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
            ]}
          />
          <.input
            field={@filter_form[:world_repo]}
            type="select"
            label="World Repo"
            options={@repo_options}
            class={[
              "mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-3 py-2.5 text-sm text-slate-100 outline-none transition hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
            ]}
          />
          <.input
            field={@filter_form[:outcome]}
            type="select"
            label="Outcome"
            options={[{"All outcomes", ""}, {"Merged", "merged"}, {"Abandoned", "abandoned"}]}
            class={[
              "mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-3 py-2.5 text-sm text-slate-100 outline-none transition hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
            ]}
          />
        </.form>

        <section
          id="task-history"
          class={[
            "overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/75 shadow-2xl shadow-black/15"
          ]}
        >
          <div class={[
            "flex items-center justify-between border-b border-slate-800 px-5 py-4 sm:px-6"
          ]}>
            <h2 class={["text-sm font-semibold text-slate-200"]}>Recorded Tasks</h2>
            <span
              id="task-count"
              class={["rounded-full bg-slate-950 px-2.5 py-1 font-mono text-xs text-slate-500"]}
            >
              {@task_count}
            </span>
          </div>

          <div id="task-list" phx-update="stream">
            <div
              id="tasks-empty"
              class={["hidden only:block px-6 py-12 text-center text-sm text-slate-500"]}
            >
              No Tasks match this view.
            </div>
            <article
              :for={{id, task} <- @streams.tasks}
              id={id}
              data-lane={task.lane}
              data-repo={task.world_repo}
              data-outcome={task.status}
              class={[
                "grid gap-4 border-b border-slate-800 px-5 py-5 last:border-b-0 sm:grid-cols-[5rem_minmax(0,1fr)_9rem] sm:items-center sm:px-6"
              ]}
            >
              <div>
                <p class={[
                  "font-mono text-[0.62rem] font-semibold uppercase tracking-[0.18em] text-slate-600"
                ]}>
                  Lane
                </p>
                <p class={["mt-1 font-mono text-sm font-semibold text-slate-300"]}>{task.lane}</p>
              </div>
              <div class={["min-w-0"]}>
                <h3 class={["truncate text-sm font-semibold text-slate-100"]}>{task.title}</h3>
                <p class={["mt-1 truncate font-mono text-xs text-slate-500"]}>
                  {task.world_repo}
                </p>
              </div>
              <div class={["sm:text-right"]}>
                <span class={[
                  "inline-flex rounded-md border px-2.5 py-1 font-mono text-[0.65rem] font-semibold uppercase tracking-[0.1em]",
                  outcome_class(task.status)
                ]}>
                  {task.status}
                </span>
                <p class={["mt-2 font-mono text-[0.65rem] text-slate-600"]}>
                  {format_time(task.started_at)}
                </p>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M UTC")
  end

  defp empty_filters do
    %{"lane" => "", "world_repo" => "", "outcome" => ""}
  end

  defp filters_from_params(params) do
    empty_filters()
    |> Map.merge(Map.take(params, ["lane", "world_repo", "outcome"]))
  end

  defp lane_options(lanes) do
    [{"All lanes", ""} | Enum.map(lanes, &{"Lane #{&1}", Integer.to_string(&1)})]
  end

  defp repo_options(world_repos) do
    [{"All World Repos", ""} | Enum.map(world_repos, &{&1, &1})]
  end

  defp outcome_class("merged"), do: "border-emerald-300/15 bg-emerald-300/5 text-emerald-300"
  defp outcome_class("abandoned"), do: "border-rose-300/15 bg-rose-300/5 text-rose-300"
  defp outcome_class(_status), do: "border-amber-300/15 bg-amber-300/5 text-amber-300"
end
