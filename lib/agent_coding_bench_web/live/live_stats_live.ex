defmodule AgentCodingBenchWeb.LiveStatsLive do
  use AgentCodingBenchWeb, :live_view

  alias AgentCodingBench.Stats
  alias AgentCodingBench.World

  @fresh_for_seconds 15
  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    world_running? = world_runtime().running?()
    now = DateTime.utc_now()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(AgentCodingBench.PubSub, "stats")
      Phoenix.PubSub.subscribe(AgentCodingBench.PubSub, "world")
      schedule_freshness_tick()
    end

    snapshot = Stats.live_snapshot(now: now, world_running?: world_running?)

    {:ok,
     socket
     |> assign(:page_title, "Live stats")
     |> assign(:world_running?, world_running?)
     |> assign(:now, now)
     |> assign(:snapshot, snapshot)
     |> assign(:source_state, source_state(world_running?, snapshot.latest_scrape_at, now))}
  end

  @impl true
  def handle_info({:stats_scraped, _scrape}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:run_status, _status}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:world_status, %{running?: running?}}, socket) do
    {:noreply, socket |> assign(:world_running?, running?) |> refresh()}
  end

  def handle_info(:freshness_tick, socket) do
    schedule_freshness_tick()
    now = DateTime.utc_now()

    {:noreply,
     socket
     |> assign(:now, now)
     |> assign(
       :source_state,
       source_state(socket.assigns.world_running?, socket.assigns.snapshot.latest_scrape_at, now)
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="live-stats-page" class={["mx-auto w-full max-w-[90rem] px-5 py-8 sm:px-8 lg:py-12"]}>
        <header class={["mb-7 flex flex-col gap-6 xl:flex-row xl:items-end xl:justify-between"]}>
          <div class={["max-w-2xl"]}>
            <div class={["mb-3 flex items-center gap-3"]}>
              <span class={["h-px w-8 bg-cyan-400/70"]}></span>
              <span class={[
                "font-mono text-[0.68rem] font-semibold uppercase tracking-[0.28em] text-cyan-300"
              ]}>
                Live instrument panel
              </span>
            </div>
            <h1 class={["text-3xl font-semibold tracking-[-0.04em] text-slate-50 sm:text-4xl"]}>
              World telemetry
            </h1>
            <p class={["mt-3 max-w-xl text-sm leading-6 text-slate-400 sm:text-base"]}>
              Serving pressure and workload activity on one shared fifteen-minute clock.
            </p>
          </div>

          <div class={["flex flex-wrap items-center gap-3"]}>
            <div
              id="stats-source"
              data-state={@source_state}
              class={[
                "inline-flex items-center gap-2 rounded-xl border px-3.5 py-2.5 font-mono text-[0.68rem] font-semibold uppercase tracking-[0.12em]",
                source_badge_class(@source_state)
              ]}
            >
              <span class={["relative flex size-2"]}>
                <span
                  :if={@source_state == :fresh}
                  class={[
                    "absolute inline-flex size-full animate-ping rounded-full bg-emerald-300 opacity-50"
                  ]}
                >
                </span>
                <span class={[
                  "relative inline-flex size-2 rounded-full",
                  source_dot_class(@source_state)
                ]}>
                </span>
              </span>
              {source_label(@source_state)}
            </div>
            <.link
              navigate={~p"/"}
              id="live-world-link"
              class={[
                "inline-flex items-center gap-2 rounded-xl border border-slate-700 bg-slate-900/80 px-3.5 py-2.5 text-sm font-semibold text-slate-300 transition hover:-translate-y-0.5 hover:border-cyan-300/30 hover:text-cyan-200"
              ]}
            >
              <.icon name="hero-command-line" class="size-4" /> World controls
            </.link>
            <.link
              navigate={~p"/runs/compare"}
              id="live-compare-link"
              class={[
                "inline-flex items-center gap-2 rounded-xl border border-slate-700 bg-slate-900/80 px-3.5 py-2.5 text-sm font-semibold text-slate-300 transition hover:-translate-y-0.5 hover:border-cyan-300/30 hover:text-cyan-200"
              ]}
            >
              <.icon name="hero-arrows-right-left" class="size-4" /> Compare Runs
            </.link>
          </div>
        </header>

        <section
          id="live-window"
          data-seconds={@snapshot.window.seconds}
          class={[
            "mb-5 flex flex-col gap-3 rounded-2xl border border-slate-800 bg-slate-900/65 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
          ]}
        >
          <div class={["flex items-center gap-3"]}>
            <span class={["grid size-9 place-items-center rounded-xl bg-cyan-300/10 text-cyan-300"]}>
              <.icon name="hero-clock" class="size-4" />
            </span>
            <div>
              <p class={["text-sm font-semibold text-slate-200"]}>Rolling 15 minutes</p>
              <p class={["mt-0.5 font-mono text-[0.65rem] text-slate-500"]}>
                Five-second Collector cadence
              </p>
            </div>
          </div>
          <p class={["font-mono text-xs text-slate-500"]}>
            {source_detail(@source_state, @snapshot.latest_scrape_at, @now)}
          </p>
        </section>

        <div
          :if={@source_state in [:stopped, :stale]}
          id="stats-stale-notice"
          class={[
            "mb-5 flex items-start gap-3 rounded-2xl border px-4 py-3",
            if(@source_state == :stopped,
              do: "border-slate-700 bg-slate-900/75 text-slate-400",
              else: "border-amber-300/20 bg-amber-300/5 text-amber-200"
            )
          ]}
        >
          <.icon
            name={
              if(@source_state == :stopped, do: "hero-stop-circle", else: "hero-exclamation-triangle")
            }
            class="mt-0.5 size-5 shrink-0"
          />
          <div>
            <p class={["text-sm font-semibold"]}>
              {if(@source_state == :stopped, do: "World stopped", else: "Collector data is stale")}
            </p>
            <p class={["mt-1 text-xs leading-5 opacity-75"]}>
              The final fifteen-minute window remains visible for context.
            </p>
          </div>
        </div>

        <section
          :if={@snapshot.active_run}
          id="live-active-run"
          data-run-id={@snapshot.active_run && @snapshot.active_run.id}
          data-run-name={@snapshot.active_run && @snapshot.active_run.name}
          class={[
            "mb-7 overflow-hidden rounded-2xl border border-cyan-300/20 bg-gradient-to-r from-cyan-300/[0.08] via-slate-900/80 to-slate-900/80 shadow-xl shadow-cyan-950/10"
          ]}
        >
          <div class={[
            "grid gap-5 px-5 py-5 lg:grid-cols-[minmax(14rem,1.4fr)_repeat(4,minmax(7rem,0.55fr))] lg:items-center lg:px-6"
          ]}>
            <div class={["min-w-0"]}>
              <p class={[
                "flex items-center gap-2 font-mono text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-cyan-300"
              ]}>
                <span class={["size-1.5 rounded-full bg-cyan-300"]}></span> Recording Run
              </p>
              <h2 class={["mt-2 truncate text-xl font-semibold tracking-tight text-slate-50"]}>
                {@snapshot.active_run.name}
              </h2>
              <p class={["mt-1 font-mono text-[0.68rem] text-slate-500"]}>
                {format_duration(run_elapsed(@snapshot.active_run, @now))} elapsed · {@snapshot.active_run.lane_count} lanes
              </p>
            </div>
            <.run_stat label="Tasks started" value={@snapshot.active_run.tasks_started} />
            <.run_stat label="Completed" value={@snapshot.active_run.completed} />
            <.run_stat label="Abandoned" value={@snapshot.active_run.abandoned} />
            <.run_stat label="Calls" value={@snapshot.active_run.calls} />
          </div>
        </section>

        <section
          :if={is_nil(@snapshot.active_run)}
          id="live-active-run-empty"
          class={[
            "mb-7 flex flex-col gap-3 rounded-2xl border border-dashed border-slate-800 bg-slate-950/25 px-5 py-4 sm:flex-row sm:items-center sm:justify-between"
          ]}
        >
          <div class={["flex items-center gap-3"]}>
            <span class={["grid size-9 place-items-center rounded-xl bg-slate-800/70 text-slate-500"]}>
              <.icon name="hero-chart-bar" class="size-4" />
            </span>
            <div>
              <p class={["text-sm font-semibold text-slate-300"]}>No Run is recording</p>
              <p class={["mt-0.5 text-xs text-slate-500"]}>
                Live monitoring continues independently.
              </p>
            </div>
          </div>
          <.link
            navigate={~p"/"}
            class={["text-sm font-semibold text-cyan-300 transition hover:text-cyan-200"]}
          >
            Start a Run <.icon name="hero-arrow-right" class="ml-1 inline size-4" />
          </.link>
        </section>

        <div class={[@source_state in [:stopped, :stale] && "opacity-70 transition-opacity"]}>
          <section id="serving-section">
            <.section_heading
              eyebrow="Serving"
              title="vLLM pressure"
              description="Capacity, queueing, and token delivery from the serving stack."
            />

            <div class={["grid gap-4 lg:grid-cols-2 xl:grid-cols-12"]}>
              <.metric_card
                id="serving-prompt"
                class="xl:col-span-3"
                title="Prompt throughput"
                value={last_value(@snapshot.serving.prompt)}
                unit="tok/s"
                detail="Input tokens processed"
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "prompt",
                    color: "#60a5fa",
                    dashed?: false,
                    points: @snapshot.serving.prompt
                  }
                ]}
              />
              <.metric_card
                id="serving-generation"
                class="xl:col-span-3"
                title="Generation throughput"
                value={last_value(@snapshot.serving.generation)}
                unit="tok/s"
                detail="Latest aggregate rate"
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "generation",
                    color: "#22d3ee",
                    dashed?: false,
                    points: @snapshot.serving.generation
                  }
                ]}
              />
              <.metric_card
                id="serving-requests"
                class="xl:col-span-3"
                title="Requests"
                value={last_value(@snapshot.serving.running)}
                unit="running"
                detail={"#{format_value(last_value(@snapshot.serving.waiting))} waiting"}
                data-running={last_value(@snapshot.serving.running)}
                data-waiting={last_value(@snapshot.serving.waiting)}
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "running",
                    color: "#38bdf8",
                    dashed?: false,
                    points: @snapshot.serving.running
                  },
                  %{
                    label: "waiting",
                    color: "#fbbf24",
                    dashed?: true,
                    points: @snapshot.serving.waiting
                  }
                ]}
              />
              <.metric_card
                id="serving-kv-cache"
                class="xl:col-span-3"
                title="KV-cache usage"
                value={last_value(@snapshot.serving.kv_cache)}
                unit="%"
                detail="Across serving workers"
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "usage",
                    color: "#34d399",
                    dashed?: false,
                    points: @snapshot.serving.kv_cache
                  }
                ]}
              />
              <.metric_card
                id="serving-cache"
                class="xl:col-span-3"
                title="Prompt cache"
                value={last_value(@snapshot.serving.prompt_cache_hit)}
                unit="% cached"
                detail={"#{format_value(last_value(@snapshot.serving.prefix_cache_hit))}% prefix hit"}
                data-prefix-hit={last_value(@snapshot.serving.prefix_cache_hit)}
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "cached tokens",
                    color: "#34d399",
                    dashed?: false,
                    points: @snapshot.serving.prompt_cache_hit
                  },
                  %{
                    label: "prefix hit",
                    color: "#a3e635",
                    dashed?: true,
                    points: @snapshot.serving.prefix_cache_hit
                  }
                ]}
              />
              <.metric_card
                id="serving-prefill"
                class="xl:col-span-3"
                title="Prefill latency"
                value={last_value(@snapshot.serving.prefill_p99)}
                unit="s p99"
                detail={"#{format_value(last_value(@snapshot.serving.prefill_p50))}s p50"}
                data-p50={last_value(@snapshot.serving.prefill_p50)}
                data-p99={last_value(@snapshot.serving.prefill_p99)}
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "p50",
                    color: "#fb923c",
                    dashed?: false,
                    points: @snapshot.serving.prefill_p50
                  },
                  %{
                    label: "p99",
                    color: "#fb7185",
                    dashed?: true,
                    points: @snapshot.serving.prefill_p99
                  }
                ]}
              />
              <.metric_card
                id="serving-ttft"
                class="xl:col-span-3"
                title="Time to first token"
                value={last_value(@snapshot.serving.ttft_p99)}
                unit="s p99"
                detail={"#{format_value(last_value(@snapshot.serving.ttft_p50))}s p50"}
                data-p50={last_value(@snapshot.serving.ttft_p50)}
                data-p99={last_value(@snapshot.serving.ttft_p99)}
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "p50",
                    color: "#60a5fa",
                    dashed?: false,
                    points: @snapshot.serving.ttft_p50
                  },
                  %{label: "p99", color: "#fb7185", dashed?: true, points: @snapshot.serving.ttft_p99}
                ]}
              />
              <.metric_card
                id="serving-itl"
                class="xl:col-span-3"
                title="Inter-token latency"
                value={last_value(@snapshot.serving.itl_p99)}
                unit="ms p99"
                detail={"#{format_value(last_value(@snapshot.serving.itl_p50))}ms p50"}
                data-p50={last_value(@snapshot.serving.itl_p50)}
                data-p99={last_value(@snapshot.serving.itl_p99)}
                max_seconds={@snapshot.window.seconds}
                lines={[
                  %{
                    label: "p50",
                    color: "#a78bfa",
                    dashed?: false,
                    points: @snapshot.serving.itl_p50
                  },
                  %{label: "p99", color: "#fb7185", dashed?: true, points: @snapshot.serving.itl_p99}
                ]}
              />
            </div>
          </section>

          <section id="world-section" class={["mt-10"]}>
            <.section_heading
              eyebrow="World"
              title="Workload pulse"
              description="Aggregate lane activity and outcomes without duplicating the control plane."
            />

            <div class={["grid gap-4 sm:grid-cols-2 xl:grid-cols-5"]}>
              <.world_stat
                id="world-lanes"
                icon="hero-square-3-stack-3d"
                label="Busy lanes"
                value={"#{@snapshot.world.busy_lanes}/#{@snapshot.world.lane_count}"}
                detail="Lanes carrying Tasks"
              />
              <.world_stat
                id="world-active-tasks"
                icon="hero-bolt"
                label="Active Tasks"
                value={@snapshot.world.active_tasks}
                detail="Current running rows"
              />
              <.world_stat
                id="world-call-rate"
                icon="hero-signal"
                label="Calls / minute"
                value={@snapshot.world.calls_per_minute}
                detail="Trailing sixty seconds"
              />
              <.world_stat
                id="world-completed"
                icon="hero-check-circle"
                label="Completed"
                value={@snapshot.world.completed}
                detail="Rolling fifteen minutes"
              />
              <.world_stat
                id="world-abandoned"
                icon="hero-arrow-path"
                label="Abandoned"
                value={@snapshot.world.abandoned}
                detail="Rolling fifteen minutes"
              />
            </div>

            <div
              id="world-role-mix"
              class={[
                "mt-4 overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/65 shadow-xl shadow-black/10"
              ]}
            >
              <div class={[
                "flex flex-col gap-2 border-b border-slate-800 px-5 py-4 sm:flex-row sm:items-end sm:justify-between"
              ]}>
                <div>
                  <h3 class={["text-sm font-semibold text-slate-100"]}>Role mix</h3>
                  <p class={["mt-1 text-xs text-slate-500"]}>Calls observed in the rolling window</p>
                </div>
                <p class={["font-mono text-[0.62rem] uppercase tracking-[0.14em] text-slate-600"]}>
                  {@snapshot.world.role_mix |> Enum.map(& &1.count) |> Enum.sum()} total calls
                </p>
              </div>
              <div class={["grid gap-5 px-5 py-5 sm:grid-cols-2 xl:grid-cols-4"]}>
                <div
                  :for={role <- @snapshot.world.role_mix}
                  id={"role-mix-#{role.role}"}
                  data-count={role.count}
                >
                  <div class={["mb-2 flex items-center justify-between gap-3"]}>
                    <span class={[
                      "font-mono text-[0.65rem] font-semibold uppercase tracking-[0.14em] text-slate-400"
                    ]}>
                      {role_label(role.role)}
                    </span>
                    <span class={["font-mono text-xs font-semibold tabular-nums text-slate-200"]}>
                      {role.count}
                    </span>
                  </div>
                  <div class={["h-2 overflow-hidden rounded-full bg-slate-950"]}>
                    <div
                      class={[
                        "h-full rounded-full bg-gradient-to-r from-cyan-500 to-blue-400 transition-all duration-500"
                      ]}
                      style={"width: #{role_width(role, @snapshot.world.role_mix)}%"}
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp run_stat(assigns) do
    ~H"""
    <div class={["rounded-xl border border-slate-800/80 bg-slate-950/35 px-4 py-3"]}>
      <p class={["font-mono text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-slate-500"]}>
        {@label}
      </p>
      <p class={["mt-1.5 text-xl font-semibold tabular-nums text-slate-100"]}>{@value}</p>
    </div>
    """
  end

  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp section_heading(assigns) do
    ~H"""
    <div class={["mb-4 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between"]}>
      <div>
        <p class={["font-mono text-[0.65rem] font-semibold uppercase tracking-[0.22em] text-cyan-300"]}>
          {@eyebrow}
        </p>
        <h2 class={["mt-1 text-xl font-semibold tracking-tight text-slate-100"]}>{@title}</h2>
      </div>
      <p class={["max-w-xl text-xs leading-5 text-slate-500 sm:text-right"]}>{@description}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, required: true
  attr :detail, :string, required: true
  attr :lines, :list, required: true
  attr :max_seconds, :integer, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  defp metric_card(assigns) do
    ~H"""
    <article
      id={@id}
      data-value={@value}
      class={[
        "group overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/70 shadow-xl shadow-black/10 transition hover:-translate-y-0.5 hover:border-slate-700",
        @class
      ]}
      {@rest}
    >
      <div class={["flex items-start justify-between gap-4 px-5 pt-5"]}>
        <div>
          <h3 class={["text-sm font-semibold text-slate-200"]}>{@title}</h3>
          <p class={["mt-2 flex items-baseline gap-2"]}>
            <span class={["text-3xl font-semibold tracking-tight tabular-nums text-slate-50"]}>
              {format_value(@value)}
            </span>
            <span class={[
              "font-mono text-[0.65rem] font-semibold uppercase tracking-[0.1em] text-slate-500"
            ]}>
              {@unit}
            </span>
          </p>
        </div>
        <div class={["flex flex-wrap justify-end gap-x-3 gap-y-1"]}>
          <span
            :for={line <- @lines}
            class={["inline-flex items-center gap-1.5 text-[0.62rem] text-slate-500"]}
          >
            <span
              class={["h-px w-3 border-t", line.dashed? && "border-dashed"]}
              style={"border-color: #{line.color}"}
            >
            </span>
            {line.label}
          </span>
        </div>
      </div>
      <p class={["px-5 pt-1 font-mono text-[0.62rem] text-slate-600"]}>{@detail}</p>
      <.spark_chart id={"#{@id}-chart"} lines={@lines} max_seconds={@max_seconds} />
    </article>
    """
  end

  attr :id, :string, required: true
  attr :lines, :list, required: true
  attr :max_seconds, :integer, required: true

  defp spark_chart(assigns) do
    max_value = metric_max(assigns.lines)
    has_samples? = Enum.any?(assigns.lines, &(&1.points != []))

    endpoints =
      for line <- assigns.lines,
          point = List.last(line.points),
          not is_nil(point),
          do: %{point: point, color: line.color}

    assigns =
      assigns
      |> assign(:max_value, max_value)
      |> assign(:has_samples?, has_samples?)
      |> assign(:endpoints, endpoints)

    ~H"""
    <div id={@id} class={["relative mt-4 h-24 border-t border-slate-800/80 bg-slate-950/55"]}>
      <svg
        class={["absolute inset-0 size-full"]}
        viewBox="0 0 1000 100"
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <line x1="0" y1="94" x2="1000" y2="94" stroke="rgb(51 65 85 / 0.65)" stroke-width="1" />
        <line x1="0" y1="50" x2="1000" y2="50" stroke="rgb(30 41 59 / 0.75)" stroke-width="1" />
        <polyline
          :for={line <- @lines}
          points={chart_points(line.points, @max_seconds, @max_value)}
          fill="none"
          stroke={line.color}
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-dasharray={line.dashed? && "7 6"}
          vector-effect="non-scaling-stroke"
        />
        <circle
          :for={endpoint <- @endpoints}
          cx={chart_x(endpoint.point, @max_seconds)}
          cy={chart_y(endpoint.point, @max_value)}
          r="3"
          fill={endpoint.color}
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <span
        :if={not @has_samples?}
        class={[
          "absolute inset-0 grid place-items-center font-mono text-[0.6rem] font-semibold uppercase tracking-[0.16em] text-slate-700"
        ]}
      >
        Awaiting samples
      </span>
      <span class={["absolute bottom-2 left-3 font-mono text-[0.55rem] text-slate-700"]}>−15m</span>
      <span class={["absolute bottom-2 right-3 font-mono text-[0.55rem] text-slate-700"]}>now</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :detail, :string, required: true

  defp world_stat(assigns) do
    ~H"""
    <article
      id={@id}
      class={[
        "rounded-2xl border border-slate-800 bg-slate-900/70 p-5 shadow-xl shadow-black/10 transition hover:-translate-y-0.5 hover:border-slate-700"
      ]}
    >
      <div class={["flex items-start justify-between gap-3"]}>
        <div>
          <p class={[
            "font-mono text-[0.62rem] font-semibold uppercase tracking-[0.14em] text-slate-500"
          ]}>
            {@label}
          </p>
          <p class={["mt-2 text-3xl font-semibold tracking-tight tabular-nums text-slate-50"]}>
            {@value}
          </p>
        </div>
        <span class={["grid size-9 place-items-center rounded-xl bg-cyan-300/8 text-cyan-300/80"]}>
          <.icon name={@icon} class="size-4" />
        </span>
      </div>
      <p class={["mt-3 text-xs leading-5 text-slate-600"]}>{@detail}</p>
    </article>
    """
  end

  defp refresh(socket) do
    now = DateTime.utc_now()
    snapshot = Stats.live_snapshot(now: now, world_running?: socket.assigns.world_running?)

    socket
    |> assign(:now, now)
    |> assign(:snapshot, snapshot)
    |> assign(
      :source_state,
      source_state(socket.assigns.world_running?, snapshot.latest_scrape_at, now)
    )
  end

  defp source_state(false, _latest_scrape_at, _now), do: :stopped
  defp source_state(true, nil, _now), do: :awaiting

  defp source_state(true, latest_scrape_at, now) do
    if DateTime.diff(now, latest_scrape_at) <= @fresh_for_seconds, do: :fresh, else: :stale
  end

  defp schedule_freshness_tick, do: Process.send_after(self(), :freshness_tick, @refresh_interval)

  defp world_runtime do
    Application.get_env(:agent_coding_bench, :world_runtime, World)
  end

  defp source_badge_class(:fresh),
    do: "border-emerald-300/20 bg-emerald-300/5 text-emerald-300"

  defp source_badge_class(:awaiting),
    do: "border-cyan-300/20 bg-cyan-300/5 text-cyan-300"

  defp source_badge_class(:stale), do: "border-amber-300/20 bg-amber-300/5 text-amber-300"
  defp source_badge_class(:stopped), do: "border-slate-700 bg-slate-900 text-slate-500"

  defp source_dot_class(:fresh), do: "bg-emerald-300"
  defp source_dot_class(:awaiting), do: "bg-cyan-300"
  defp source_dot_class(:stale), do: "bg-amber-300"
  defp source_dot_class(:stopped), do: "bg-slate-600"

  defp source_label(:fresh), do: "Collector live"
  defp source_label(:awaiting), do: "Awaiting scrape"
  defp source_label(:stale), do: "Collector stale"
  defp source_label(:stopped), do: "World stopped"

  defp source_detail(:awaiting, nil, _now), do: "Waiting for the first successful scrape"
  defp source_detail(_state, nil, _now), do: "No serving samples recorded"

  defp source_detail(_state, latest_scrape_at, now) do
    "Last successful scrape #{format_age(DateTime.diff(now, latest_scrape_at))} ago"
  end

  defp last_value([]), do: nil
  defp last_value(points), do: List.last(points).value

  defp metric_max(lines) do
    values = for line <- lines, point <- line.points, do: point.value
    if values == [], do: 0.0, else: Enum.max(values)
  end

  defp chart_points(points, max_seconds, max_value) do
    Enum.map_join(points, " ", fn point ->
      "#{chart_x(point, max_seconds)},#{chart_y(point, max_value)}"
    end)
  end

  defp chart_x(point, max_seconds) do
    x = if max_seconds > 0, do: point.offset_seconds / max_seconds * 1_000, else: 0.0
    Float.round(x, 1)
  end

  defp chart_y(point, max_value) do
    y = if max_value > 0, do: 94 - point.value / max_value * 88, else: 94.0
    Float.round(y, 1)
  end

  defp role_width(%{count: count}, roles) do
    max_count = roles |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)
    if max_count > 0, do: round(count / max_count * 100), else: 0
  end

  defp role_label("pm"), do: "PM"
  defp role_label(role), do: String.capitalize(role)

  defp run_elapsed(run, now), do: max(DateTime.diff(now, run.started_at), 0)

  defp format_value(nil), do: "—"
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value) do
    cond do
      value >= 1_000 -> value |> round() |> format_integer()
      value >= 100 -> value |> Float.round(0) |> trunc() |> Integer.to_string()
      value >= 10 -> :erlang.float_to_binary(value, decimals: 1)
      true -> :erlang.float_to_binary(value, decimals: 2)
    end
  end

  defp format_integer(value) when value < 1_000, do: Integer.to_string(value)

  defp format_integer(value) do
    format_integer(div(value, 1_000)) <>
      "," <> String.pad_leading(Integer.to_string(rem(value, 1_000)), 3, "0")
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"

  defp format_age(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"
  defp format_age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_age(seconds), do: "#{div(seconds, 3_600)}h"
end
