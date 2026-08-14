defmodule AgentCodingBenchWeb.WorldLive do
  use AgentCodingBenchWeb, :live_view

  alias AgentCodingBench.Stats
  alias AgentCodingBench.World

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AgentCodingBench.PubSub, "world")
    end

    active_run = Stats.active_run()
    recent_events = World.recent_task_events()
    lane_statuses = World.lane_statuses()
    world_running? = world_runtime().running?()

    {:ok,
     socket
     |> assign(:page_title, "World control")
     |> assign(:world_running?, world_running?)
     |> assign(:world_form, world_form(length(lane_statuses)))
     |> assign(:active_run, active_run)
     |> assign(:run_form, run_form(active_run))
     |> assign(:lane_numbers, MapSet.new(lane_statuses, & &1.lane))
     |> stream(:lanes, lane_statuses, dom_id: &"lane-#{&1.lane}")
     |> stream(:task_events, recent_events, dom_id: &"task-event-#{&1.id}")}
  end

  @impl true
  def handle_info({:lane_status, status}, socket) do
    {:noreply,
     socket
     |> update(:lane_numbers, &MapSet.put(&1, status.lane))
     |> stream_insert(:lanes, status)}
  end

  def handle_info({:lane_removed, lane}, socket) do
    {:noreply,
     socket
     |> update(:lane_numbers, &MapSet.delete(&1, lane))
     |> stream_delete_by_dom_id(:lanes, "lane-#{lane}")}
  end

  def handle_info({:task_event, event}, socket) do
    {:noreply, stream_insert(socket, :task_events, event, at: 0, limit: 50)}
  end

  def handle_info({:world_status, %{running?: true, lane_count: lane_count}}, socket) do
    {:noreply,
     socket
     |> assign(:world_running?, true)
     |> assign(:world_form, world_form(lane_count))}
  end

  def handle_info({:world_status, %{running?: false}}, socket) do
    {:noreply,
     socket
     |> assign(:world_running?, false)
     |> assign(:world_form, world_form(0))
     |> assign(:lane_numbers, MapSet.new())
     |> stream(:lanes, [], reset: true)}
  end

  @impl true
  def handle_event("start_run", %{"run" => run_params}, socket) do
    run_params = Map.put(run_params, "lane_count", Integer.to_string(current_lane_count(socket)))

    case Stats.start_run(run_params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:active_run, run)
         |> assign(:run_form, run_form(run))
         |> put_flash(:info, "Run started")}

      {:error, %Ecto.Changeset{} = changeset} ->
        case Stats.active_run() do
          nil ->
            {:noreply, assign(socket, :run_form, to_form(changeset, action: :insert))}

          active_run ->
            {:noreply,
             socket
             |> assign(:active_run, active_run)
             |> assign(:run_form, run_form(active_run))
             |> put_flash(:error, "Another Run was already started")}
        end

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:run_form, to_form(run_params, as: :run))
         |> put_flash(:error, "Run could not be started")}
    end
  end

  def handle_event("configure_world", %{"world" => %{"lane_count" => lane_count}}, socket) do
    with {lane_count, ""} when lane_count >= 0 <- Integer.parse(lane_count),
         :ok <- configure_world(socket.assigns.world_running?, lane_count) do
      {:noreply,
       socket
       |> assign(:world_running?, true)
       |> assign(:world_form, world_form(lane_count))
       |> put_flash(
         :info,
         if(socket.assigns.world_running?, do: "World scaled", else: "World started")
       )}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "World could not be configured")}
    end
  end

  def handle_event("stop_world", _params, socket) do
    case world_runtime().stop() do
      :ok ->
        {:noreply,
         socket
         |> assign(:world_running?, false)
         |> assign(:world_form, world_form(0))
         |> assign(:lane_numbers, MapSet.new())
         |> stream(:lanes, [], reset: true)
         |> put_flash(:info, "World stopped")}

      {:error, :not_started} ->
        {:noreply,
         socket
         |> assign(:world_running?, false)
         |> assign(:world_form, world_form(0))
         |> put_flash(:error, "World was already stopped")}
    end
  end

  def handle_event("stop_run", _params, %{assigns: %{active_run: active_run}} = socket) do
    case Stats.stop_run(active_run) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> assign(:active_run, nil)
         |> assign(:run_form, run_form(nil))
         |> put_flash(:info, "Run stopped")}

      {:error, _reason} ->
        active_run = Stats.active_run()

        {:noreply,
         socket
         |> assign(:active_run, active_run)
         |> assign(:run_form, run_form(active_run))
         |> put_flash(:error, "Run state changed elsewhere")}
    end
  end

  defp run_form(nil) do
    to_form(%{"name" => "", "notes" => ""}, as: :run)
  end

  defp run_form(run) do
    to_form(
      %{
        "name" => run.name,
        "notes" => run.notes || ""
      },
      as: :run
    )
  end

  defp world_form(lane_count) do
    to_form(%{"lane_count" => Integer.to_string(lane_count)}, as: :world)
  end

  defp current_lane_count(socket) do
    {lane_count, ""} = Integer.parse(socket.assigns.world_form.params["lane_count"])
    lane_count
  end

  defp configure_world(true, lane_count), do: world_runtime().scale_lanes(lane_count)

  defp configure_world(false, lane_count) do
    case world_runtime().start(lane_count) do
      {:ok, _pid} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp world_runtime do
    Application.get_env(:agent_coding_bench, :world_runtime, World)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="world-page" class={["mx-auto w-full max-w-7xl px-5 py-8 sm:px-8 lg:py-12"]}>
        <header class={["mb-8 flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between"]}>
          <div class={["max-w-2xl"]}>
            <div class={["mb-3 flex items-center gap-3"]}>
              <span class={["h-px w-8 bg-cyan-400/70"]}></span>
              <span class={[
                "font-mono text-[0.68rem] font-semibold uppercase tracking-[0.28em] text-cyan-300"
              ]}>
                Control plane
              </span>
            </div>
            <h1 class={["text-3xl font-semibold tracking-[-0.04em] text-slate-50 sm:text-4xl"]}>
              Agent coding world
            </h1>
            <p class={["mt-3 max-w-xl text-sm leading-6 text-slate-400 sm:text-base"]}>
              Shape the workload, mark an observation window, and keep the serving box in view.
            </p>
          </div>

          <div
            id="world-status"
            data-state={if(@world_running?, do: "up", else: "down")}
            class={[
              "inline-flex w-fit items-center gap-2 rounded-full border border-slate-700/80 bg-slate-900/70 px-3.5 py-2 text-xs font-semibold text-slate-300 shadow-sm shadow-black/20"
            ]}
          >
            <span class={["relative flex size-2"]}>
              <span class={[
                "absolute inline-flex size-full rounded-full opacity-50",
                if(@world_running?, do: "animate-ping bg-emerald-400", else: "bg-slate-500")
              ]}>
              </span>
              <span class={[
                "relative inline-flex size-2 rounded-full",
                if(@world_running?, do: "bg-emerald-400", else: "bg-slate-500")
              ]}>
              </span>
            </span>
            {if(@world_running?, do: "World up", else: "World down")}
          </div>
        </header>

        <div class={["grid gap-5 lg:grid-cols-[0.9fr_1.1fr]"]}>
          <.form for={@world_form} id="world-form" phx-submit="configure_world">
            <section
              id="world-controls"
              class={[
                "overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/75 shadow-2xl shadow-black/15"
              ]}
            >
              <div class={["border-b border-slate-800 px-6 py-5"]}>
                <div class={["flex items-start justify-between gap-4"]}>
                  <div>
                    <p class={[
                      "font-mono text-[0.65rem] font-semibold uppercase tracking-[0.24em] text-slate-500"
                    ]}>
                      Workload
                    </p>
                    <h2 class={["mt-1.5 text-lg font-semibold text-slate-100"]}>World</h2>
                  </div>
                  <div class={[
                    "rounded-lg border px-2.5 py-1 text-[0.68rem] font-medium",
                    if(@world_running?,
                      do: "border-emerald-400/20 bg-emerald-400/5 text-emerald-300/80",
                      else: "border-slate-700 bg-slate-950/50 text-slate-500"
                    )
                  ]}>
                    {if(@world_running?, do: "Runtime active", else: "Runtime stopped")}
                  </div>
                </div>
              </div>

              <div class={["space-y-6 px-6 py-6"]}>
                <div>
                  <.input
                    field={@world_form[:lane_count]}
                    type="number"
                    min="0"
                    step="1"
                    label="Lanes"
                    class={[
                      "mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-4 py-3 text-base font-semibold text-slate-100 outline-none transition placeholder:text-slate-600 hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
                    ]}
                    error_class={[
                      "mt-2 w-full rounded-xl border border-rose-400 bg-slate-950/80 px-4 py-3 text-base font-semibold text-slate-100 outline-none ring-4 ring-rose-400/10"
                    ]}
                  />
                  <p class={["mt-2 text-xs leading-5 text-slate-500"]}>
                    Zero lanes captures an idle serving baseline.
                  </p>
                </div>

                <div class={["grid grid-cols-2 gap-3"]}>
                  <button
                    id={if(@world_running?, do: "world-scale", else: "world-start")}
                    type="submit"
                    class={[
                      "inline-flex items-center justify-center gap-2 rounded-xl bg-cyan-300 px-4 py-3 text-sm font-bold text-slate-950 transition hover:-translate-y-0.5 hover:bg-cyan-200 focus:outline-none focus:ring-4 focus:ring-cyan-300/20 active:translate-y-0"
                    ]}
                  >
                    <.icon name="hero-play-solid" class="size-4" />
                    {if(@world_running?, do: "Scale world", else: "Start world")}
                  </button>
                  <button
                    id="world-stop"
                    type="button"
                    disabled={not @world_running?}
                    phx-click="stop_world"
                    class={[
                      "inline-flex items-center justify-center gap-2 rounded-xl border px-4 py-3 text-sm font-semibold transition",
                      if(@world_running?,
                        do: "border-rose-300/30 bg-rose-300/5 text-rose-200 hover:bg-rose-300/10",
                        else: "cursor-not-allowed border-slate-800 bg-transparent text-slate-600"
                      )
                    ]}
                  >
                    <.icon name="hero-stop-solid" class="size-4" /> Stop world
                  </button>
                </div>
              </div>
            </section>
          </.form>

          <.form for={@run_form} id="run-form" phx-submit="start_run">
            <section
              id="run-controls"
              class={[
                "overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/75 shadow-2xl shadow-black/15"
              ]}
            >
              <div class={["border-b border-slate-800 px-6 py-5"]}>
                <p class={[
                  "font-mono text-[0.65rem] font-semibold uppercase tracking-[0.24em] text-slate-500"
                ]}>
                  Observation window
                </p>
                <h2 class={["mt-1.5 text-lg font-semibold text-slate-100"]}>New Run</h2>
              </div>

              <div class={["space-y-4 px-6 py-6"]}>
                <%= if @active_run do %>
                  <div
                    id="active-run"
                    data-run-name={@active_run.name}
                    data-lane-count={@active_run.lane_count}
                    class={["rounded-xl border border-cyan-300/20 bg-cyan-300/5 p-5"]}
                  >
                    <div class={["flex items-start justify-between gap-4"]}>
                      <div>
                        <div class={[
                          "mb-2 flex items-center gap-2 text-xs font-semibold text-cyan-300"
                        ]}>
                          <span class={["relative flex size-2"]}>
                            <span class={[
                              "absolute inline-flex size-full animate-ping rounded-full bg-cyan-300 opacity-50"
                            ]}>
                            </span>
                            <span class={["relative inline-flex size-2 rounded-full bg-cyan-300"]}>
                            </span>
                          </span>
                          Recording
                        </div>
                        <h3 class={["text-xl font-semibold tracking-tight text-slate-50"]}>
                          {@active_run.name}
                        </h3>
                      </div>
                      <span class={[
                        "rounded-lg border border-slate-700 bg-slate-950/60 px-2.5 py-1 font-mono text-xs text-slate-400"
                      ]}>
                        {@active_run.lane_count} lanes
                      </span>
                    </div>

                    <p
                      :if={@active_run.notes not in [nil, ""]}
                      class={["mt-4 text-sm leading-6 text-slate-400"]}
                    >
                      {@active_run.notes}
                    </p>
                  </div>

                  <button
                    id="run-stop"
                    type="button"
                    phx-click="stop_run"
                    class={[
                      "group inline-flex w-full items-center justify-center gap-2 rounded-xl border border-rose-300/30 bg-rose-300/5 px-4 py-3 text-sm font-bold text-rose-200 transition hover:-translate-y-0.5 hover:border-rose-300/50 hover:bg-rose-300/10 focus:outline-none focus:ring-4 focus:ring-rose-300/10 active:translate-y-0 disabled:cursor-wait disabled:opacity-60"
                    ]}
                  >
                    <.icon name="hero-stop-solid" class="size-4" /> Stop Run
                  </button>
                <% else %>
                  <.input
                    field={@run_form[:name]}
                    type="text"
                    required
                    autocomplete="off"
                    label="Name"
                    placeholder="e.g. idle baseline"
                    class={[
                      "mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-4 py-3 text-sm text-slate-100 outline-none transition placeholder:text-slate-600 hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
                    ]}
                    error_class="mt-2 w-full rounded-xl border border-rose-400 bg-slate-950/80 px-4 py-3 text-sm text-slate-100 outline-none ring-4 ring-rose-400/10"
                  />
                  <.input
                    field={@run_form[:notes]}
                    type="textarea"
                    rows="4"
                    label="Notes"
                    placeholder="What are you looking for in this window?"
                    class={[
                      "mt-2 min-h-28 w-full resize-y rounded-xl border border-slate-700 bg-slate-950/80 px-4 py-3 text-sm leading-6 text-slate-100 outline-none transition placeholder:text-slate-600 hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
                    ]}
                    error_class="mt-2 min-h-28 w-full resize-y rounded-xl border border-rose-400 bg-slate-950/80 px-4 py-3 text-sm leading-6 text-slate-100 outline-none ring-4 ring-rose-400/10"
                  />

                  <button
                    id="run-start"
                    type="submit"
                    class={[
                      "group mt-1 inline-flex w-full items-center justify-center gap-2 rounded-xl bg-cyan-300 px-4 py-3 text-sm font-bold text-slate-950 shadow-lg shadow-cyan-950/30 transition hover:-translate-y-0.5 hover:bg-cyan-200 hover:shadow-cyan-900/30 focus:outline-none focus:ring-4 focus:ring-cyan-300/20 active:translate-y-0 disabled:cursor-wait disabled:opacity-60"
                    ]}
                  >
                    <.icon
                      name="hero-record-circle-solid"
                      class="size-4 transition group-hover:scale-110"
                    /> Start Run
                  </button>
                <% end %>
              </div>
            </section>
          </.form>
        </div>

        <section id="lane-section" class={["mt-8"]}>
          <div class={["mb-4 flex items-end justify-between gap-4"]}>
            <div>
              <p class={[
                "font-mono text-[0.65rem] font-semibold uppercase tracking-[0.24em] text-slate-500"
              ]}>
                Live workload
              </p>
              <h2 class={["mt-1.5 text-xl font-semibold text-slate-100"]}>Lanes</h2>
            </div>
            <span
              id="lane-count"
              class={[
                "rounded-full border border-slate-800 bg-slate-900 px-3 py-1 font-mono text-xs text-slate-400"
              ]}
            >
              {MapSet.size(@lane_numbers)} active
            </span>
          </div>

          <div id="lane-grid" phx-update="stream" class={["grid gap-4 md:grid-cols-2 xl:grid-cols-3"]}>
            <div
              id="lanes-empty"
              class={[
                "hidden only:block rounded-2xl border border-dashed border-slate-800 bg-slate-900/40 px-6 py-10 text-center text-sm text-slate-500 md:col-span-2 xl:col-span-3"
              ]}
            >
              Lane status will appear when the World starts.
            </div>
            <article
              :for={{id, lane} <- @streams.lanes}
              id={id}
              data-state={lane.state}
              data-task-id={lane.task_id}
              data-repo={lane.world_repo}
              class={[
                "group rounded-2xl border border-slate-800 bg-slate-900/75 p-5 shadow-xl shadow-black/10 transition hover:-translate-y-0.5 hover:border-slate-700"
              ]}
            >
              <div class={["flex items-start justify-between gap-4"]}>
                <div>
                  <p class={[
                    "font-mono text-[0.62rem] font-semibold uppercase tracking-[0.22em] text-slate-500"
                  ]}>
                    Lane {lane.lane}
                  </p>
                  <p class={["mt-2 text-base font-semibold capitalize text-cyan-200"]}>
                    {lane.state}
                  </p>
                </div>
                <span class={["relative mt-1 flex size-2"]}>
                  <span class={[
                    "absolute inline-flex size-full animate-ping rounded-full bg-cyan-300 opacity-40"
                  ]}>
                  </span>
                  <span class={["relative inline-flex size-2 rounded-full bg-cyan-300"]}></span>
                </span>
              </div>

              <p
                data-role="task-title"
                class={["mt-5 min-h-12 text-sm font-medium leading-6 text-slate-200"]}
              >
                {lane.task_title || "Inventing the next task"}
              </p>
              <p class={["mt-2 truncate font-mono text-xs text-slate-500"]}>
                {lane.world_repo || "Choosing a World Repo"}
              </p>

              <dl class={["mt-5 grid grid-cols-2 gap-3 border-t border-slate-800 pt-4"]}>
                <div>
                  <dt class={["text-[0.68rem] text-slate-500"]}>In state</dt>
                  <dd
                    id={"lane-#{lane.lane}-state-age"}
                    data-role="time-in-state"
                    data-at={lane.state_started_at && DateTime.to_iso8601(lane.state_started_at)}
                    phx-hook=".RelativeTime"
                    phx-update="ignore"
                    class={["mt-1 font-mono text-xs font-semibold text-slate-300"]}
                  >
                    —
                  </dd>
                </div>
                <div>
                  <dt class={["text-[0.68rem] text-slate-500"]}>Last event</dt>
                  <dd
                    id={"lane-#{lane.lane}-event-age"}
                    data-role="last-event-age"
                    data-at={lane.last_event_at && DateTime.to_iso8601(lane.last_event_at)}
                    phx-hook=".RelativeTime"
                    phx-update="ignore"
                    class={["mt-1 font-mono text-xs font-semibold text-slate-300"]}
                  >
                    —
                  </dd>
                </div>
              </dl>
            </article>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".RelativeTime">
            export default {
              mounted() {
                this.renderAge()
                this.timer = window.setInterval(() => this.renderAge(), 1000)
              },
              updated() {
                this.renderAge()
              },
              destroyed() {
                window.clearInterval(this.timer)
              },
              renderAge() {
                const at = this.el.dataset.at

                if (!at) {
                  this.el.textContent = "—"
                  return
                }

                const seconds = Math.max(Math.floor((Date.now() - Date.parse(at)) / 1000), 0)

                if (seconds < 60) {
                  this.el.textContent = `${seconds}s`
                } else if (seconds < 3600) {
                  this.el.textContent = `${Math.floor(seconds / 60)}m`
                } else {
                  this.el.textContent = `${Math.floor(seconds / 3600)}h`
                }
              }
            }
          </script>
        </section>

        <section id="event-section" class={["mt-8"]}>
          <div class={["mb-4 flex items-end justify-between gap-4"]}>
            <div>
              <p class={[
                "font-mono text-[0.65rem] font-semibold uppercase tracking-[0.24em] text-slate-500"
              ]}>
                Person transcript
              </p>
              <h2 class={["mt-1.5 text-xl font-semibold text-slate-100"]}>Recent events</h2>
            </div>
            <div class={["flex items-center gap-2"]}>
              <.link
                navigate={~p"/stats/live"}
                id="live-stats-link"
                class={[
                  "inline-flex items-center gap-2 rounded-lg border border-cyan-300/20 bg-cyan-300/5 px-3 py-2 text-xs font-semibold text-cyan-200 transition hover:-translate-y-0.5 hover:border-cyan-300/40 hover:bg-cyan-300/10"
                ]}
              >
                Live stats <.icon name="hero-signal" class="size-3.5" />
              </.link>
              <.link
                navigate={~p"/runs/compare"}
                id="run-compare-link"
                class={[
                  "inline-flex items-center gap-2 rounded-lg border border-slate-800 bg-slate-900 px-3 py-2 text-xs font-semibold text-slate-300 transition hover:border-cyan-300/30 hover:text-cyan-200"
                ]}
              >
                Compare Runs <.icon name="hero-arrows-right-left" class="size-3.5" />
              </.link>
              <.link
                navigate={~p"/tasks"}
                id="task-history-link"
                class={[
                  "inline-flex items-center gap-2 rounded-lg border border-slate-800 bg-slate-900 px-3 py-2 text-xs font-semibold text-slate-300 transition hover:border-cyan-300/30 hover:text-cyan-200"
                ]}
              >
                Task history <.icon name="hero-arrow-right" class="size-3.5" />
              </.link>
            </div>
          </div>

          <div
            id="task-event-tail"
            phx-update="stream"
            class={[
              "overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/75 shadow-2xl shadow-black/10"
            ]}
          >
            <div
              id="task-events-empty"
              class={["hidden only:block px-6 py-10 text-center text-sm text-slate-500"]}
            >
              Task events will appear as the cast works.
            </div>
            <article
              :for={{id, event} <- @streams.task_events}
              id={id}
              data-kind={event.kind}
              data-task-id={event.task_id}
              class={[
                "grid gap-3 border-b border-slate-800 px-5 py-4 last:border-b-0 sm:grid-cols-[8rem_1fr] sm:px-6"
              ]}
            >
              <div>
                <span class={[
                  "inline-flex rounded-md border border-cyan-300/15 bg-cyan-300/5 px-2 py-1 font-mono text-[0.62rem] font-semibold uppercase tracking-[0.12em] text-cyan-300"
                ]}>
                  {event.kind}
                </span>
                <p class={["mt-2 font-mono text-[0.65rem] text-slate-600"]}>
                  Lane {event.task.lane}
                </p>
              </div>
              <div class={["min-w-0"]}>
                <div class={["flex flex-wrap items-baseline gap-x-2 gap-y-1"]}>
                  <p class={["text-sm font-semibold text-slate-200"]}>{event.task.title}</p>
                  <p class={["font-mono text-[0.65rem] text-slate-600"]}>
                    {event.task.world_repo}
                  </p>
                </div>
                <p class={["mt-2 whitespace-pre-wrap text-sm leading-6 text-slate-400"]}>
                  {event.content}
                </p>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
