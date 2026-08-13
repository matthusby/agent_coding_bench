defmodule AgentCodingBenchWeb.WorldLive do
  use AgentCodingBenchWeb, :live_view

  alias AgentCodingBench.Stats

  @impl true
  def mount(_params, _session, socket) do
    active_run = Stats.active_run()

    {:ok,
     socket
     |> assign(:page_title, "World control")
     |> assign(:active_run, active_run)
     |> assign(:run_form, run_form(active_run))}
  end

  @impl true
  def handle_event("start_run", %{"run" => run_params}, socket) do
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
    to_form(%{"lane_count" => "0", "name" => "", "notes" => ""}, as: :run)
  end

  defp run_form(run) do
    to_form(
      %{
        "lane_count" => Integer.to_string(run.lane_count),
        "name" => run.name,
        "notes" => run.notes || ""
      },
      as: :run
    )
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
            data-state="down"
            class={[
              "inline-flex w-fit items-center gap-2 rounded-full border border-slate-700/80 bg-slate-900/70 px-3.5 py-2 text-xs font-semibold text-slate-300 shadow-sm shadow-black/20"
            ]}
          >
            <span class={["relative flex size-2"]}>
              <span class={["absolute inline-flex size-full rounded-full bg-slate-500 opacity-50"]}>
              </span>
              <span class={["relative inline-flex size-2 rounded-full bg-slate-500"]}></span>
            </span>
            World down
          </div>
        </header>

        <.form for={@run_form} id="run-form" phx-submit="start_run">
          <div class={["grid gap-5 lg:grid-cols-[0.9fr_1.1fr]"]}>
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
                    "rounded-lg border border-amber-400/20 bg-amber-400/5 px-2.5 py-1 text-[0.68rem] font-medium text-amber-300/80"
                  ]}>
                    Runtime pending
                  </div>
                </div>
              </div>

              <div class={["space-y-6 px-6 py-6"]}>
                <div>
                  <.input
                    field={@run_form[:lane_count]}
                    type="number"
                    min="0"
                    step="1"
                    disabled={not is_nil(@active_run)}
                    label="Lanes"
                    class="mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-4 py-3 text-base font-semibold text-slate-100 outline-none transition placeholder:text-slate-600 hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
                    error_class="mt-2 w-full rounded-xl border border-rose-400 bg-slate-950/80 px-4 py-3 text-base font-semibold text-slate-100 outline-none ring-4 ring-rose-400/10"
                  />
                  <p class={["mt-2 text-xs leading-5 text-slate-500"]}>
                    Zero lanes captures an idle serving baseline.
                  </p>
                </div>

                <div class={["grid grid-cols-2 gap-3"]}>
                  <button
                    id="world-start"
                    type="button"
                    disabled
                    class={[
                      "inline-flex cursor-not-allowed items-center justify-center gap-2 rounded-xl border border-slate-700 bg-slate-800/60 px-4 py-3 text-sm font-semibold text-slate-500"
                    ]}
                  >
                    <.icon name="hero-play-solid" class="size-4" /> Start world
                  </button>
                  <button
                    id="world-stop"
                    type="button"
                    disabled
                    class={[
                      "inline-flex cursor-not-allowed items-center justify-center gap-2 rounded-xl border border-slate-800 bg-transparent px-4 py-3 text-sm font-semibold text-slate-600"
                    ]}
                  >
                    <.icon name="hero-stop-solid" class="size-4" /> Stop world
                  </button>
                </div>

                <p class={[
                  "rounded-xl border border-slate-800 bg-slate-950/50 px-4 py-3 text-xs leading-5 text-slate-500"
                ]}>
                  World supervision and live lane scaling arrive with milestone 6. Run windows are ready now for manual load.
                </p>
              </div>
            </section>

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
                    class="mt-2 w-full rounded-xl border border-slate-700 bg-slate-950/80 px-4 py-3 text-sm text-slate-100 outline-none transition placeholder:text-slate-600 hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
                    error_class="mt-2 w-full rounded-xl border border-rose-400 bg-slate-950/80 px-4 py-3 text-sm text-slate-100 outline-none ring-4 ring-rose-400/10"
                  />
                  <.input
                    field={@run_form[:notes]}
                    type="textarea"
                    rows="4"
                    label="Notes"
                    placeholder="What are you looking for in this window?"
                    class="mt-2 min-h-28 w-full resize-y rounded-xl border border-slate-700 bg-slate-950/80 px-4 py-3 text-sm leading-6 text-slate-100 outline-none transition placeholder:text-slate-600 hover:border-slate-600 focus:border-cyan-400 focus:ring-4 focus:ring-cyan-400/10"
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
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
