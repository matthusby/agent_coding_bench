defmodule AgentCodingBenchWeb.RunCompareLive do
  use AgentCodingBenchWeb, :live_view

  alias AgentCodingBench.Stats

  @line_metadata [
    generation: %{label: "generation", dashed?: false},
    p50: %{label: "p50", dashed?: false},
    p99: %{label: "p99", dashed?: true},
    running: %{label: "running", dashed?: false},
    waiting: %{label: "waiting", dashed?: true},
    usage: %{label: "usage", dashed?: false}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Run comparison")
     |> assign(:can_compare?, false)
     |> assign(:run_options, [])
     |> assign(:comparison, nil)
     |> assign(:compare_form, to_form(%{"run_a" => "", "run_b" => ""}, as: :compare))
     |> stream(:metrics, [], dom_id: &"metric-row-#{&1.key}")
     |> stream(:workload, [], dom_id: &"workload-row-#{&1.key}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    runs = Stats.list_runs()

    case selected_runs(runs, params) do
      {run_a, run_b} ->
        comparison = Stats.compare_runs!(run_a.id, run_b.id)

        {:noreply,
         socket
         |> assign(:can_compare?, length(runs) >= 2)
         |> assign(:run_options, run_options(runs))
         |> assign(:comparison, Map.drop(comparison, [:metrics, :workload]))
         |> assign(
           :compare_form,
           to_form(
             %{"run_a" => Integer.to_string(run_a.id), "run_b" => Integer.to_string(run_b.id)},
             as: :compare
           )
         )
         |> stream(:metrics, comparison.metrics, reset: true)
         |> stream(:workload, comparison.workload, reset: true)}

      nil ->
        {:noreply,
         socket
         |> assign(:can_compare?, length(runs) >= 2)
         |> assign(:run_options, run_options(runs))
         |> assign(:comparison, nil)
         |> stream(:metrics, [], reset: true)
         |> stream(:workload, [], reset: true)}
    end
  end

  @impl true
  def handle_event("compare", %{"compare" => %{"run_a" => run_a, "run_b" => run_b}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/runs/compare?#{%{run_a: run_a, run_b: run_b}}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="run-compare-page" class={["mx-auto w-full max-w-[90rem] px-5 py-8 sm:px-8 lg:py-12"]}>
        <header class={["mb-7 flex flex-col gap-6 xl:flex-row xl:items-end xl:justify-between"]}>
          <div class={["max-w-2xl"]}>
            <div class={["mb-3 flex items-center gap-3"]}>
              <span class={["h-px w-8 bg-cyan-400/70"]}></span>
              <span class={[
                "font-mono text-[0.68rem] font-semibold uppercase tracking-[0.28em] text-cyan-300"
              ]}>
                Observation ledger
              </span>
            </div>
            <h1 class={["text-3xl font-semibold tracking-[-0.04em] text-slate-50 sm:text-4xl"]}>
              Run comparison
            </h1>
            <p class={["mt-3 max-w-xl text-sm leading-6 text-slate-400 sm:text-base"]}>
              Compare serving behavior and World throughput on a shared offset-from-start clock.
            </p>
          </div>

          <.form
            for={@compare_form}
            id="run-compare-form"
            phx-submit="compare"
            class={[
              "grid gap-3 rounded-2xl border border-slate-800 bg-slate-900/75 p-4 shadow-xl shadow-black/10 sm:grid-cols-[minmax(11rem,1fr)_auto_minmax(11rem,1fr)_auto] sm:items-end"
            ]}
          >
            <.input
              field={@compare_form[:run_a]}
              type="select"
              label="Run A"
              options={@run_options}
              disabled={@run_options == []}
              class={[
                "mt-1.5 w-full rounded-xl border border-blue-300/20 bg-slate-950 px-3 py-2.5 text-sm text-slate-100 outline-none transition hover:border-blue-300/40 focus:border-blue-400 focus:ring-4 focus:ring-blue-400/10"
              ]}
            />
            <span class={["hidden pb-3 font-mono text-xs text-slate-600 sm:block"]}>VS</span>
            <.input
              field={@compare_form[:run_b]}
              type="select"
              label="Run B"
              options={@run_options}
              disabled={@run_options == []}
              class={[
                "mt-1.5 w-full rounded-xl border border-orange-300/20 bg-slate-950 px-3 py-2.5 text-sm text-slate-100 outline-none transition hover:border-orange-300/40 focus:border-orange-400 focus:ring-4 focus:ring-orange-400/10"
              ]}
            />
            <button
              id="run-compare-submit"
              type="submit"
              disabled={not @can_compare?}
              class={[
                "inline-flex h-[2.7rem] items-center justify-center gap-2 rounded-xl border border-cyan-300/20 bg-cyan-300/10 px-4 text-sm font-semibold text-cyan-200 transition hover:-translate-y-0.5 hover:border-cyan-300/40 hover:bg-cyan-300/15 disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:translate-y-0"
              ]}
            >
              Compare <.icon name="hero-arrows-right-left" class="size-4" />
            </button>
          </.form>
        </header>

        <%= if @comparison do %>
          <section class={["mb-5 grid gap-3 lg:grid-cols-[1fr_auto_1fr] lg:items-center"]}>
            <.run_chip id="run-chip-a" run={@comparison.runs.a} side={:a} />
            <div
              id="config-match"
              data-match={to_string(@comparison.config_match?)}
              class={[
                "mx-auto inline-flex w-fit items-center gap-2 rounded-full border px-3 py-1.5 font-mono text-[0.65rem] font-semibold uppercase tracking-[0.12em]",
                if(@comparison.config_match?,
                  do: "border-emerald-300/20 bg-emerald-300/5 text-emerald-300",
                  else: "border-amber-300/20 bg-amber-300/5 text-amber-300"
                )
              ]}
            >
              <.icon
                name={
                  if(@comparison.config_match?,
                    do: "hero-check-circle",
                    else: "hero-exclamation-triangle"
                  )
                }
                class="size-4"
              />
              {if(@comparison.config_match?,
                do: "Serving config match",
                else: "Serving config differs"
              )}
            </div>
            <.run_chip id="run-chip-b" run={@comparison.runs.b} side={:b} />
          </section>

          <section
            id="run-ledger"
            class={[
              "overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/65 shadow-2xl shadow-black/20"
            ]}
          >
            <div class={[
              "hidden grid-cols-[minmax(10rem,1.15fr)_minmax(13rem,2fr)_7rem_minmax(13rem,2fr)] items-center gap-5 border-b border-slate-800 bg-slate-950/45 px-5 py-3 font-mono text-[0.62rem] font-semibold uppercase tracking-[0.15em] text-slate-500 md:grid lg:px-6"
            ]}>
              <span>Metric</span>
              <span class={["flex items-center gap-2 text-blue-300"]}>
                <span class={["size-2 rounded-full bg-blue-400"]}></span> Run A
              </span>
              <span class={["text-center"]}>Δ B vs A</span>
              <span class={["flex items-center gap-2 text-orange-300"]}>
                <span class={["size-2 rounded-full bg-orange-400"]}></span> Run B
              </span>
            </div>

            <div id="metric-ledger" phx-update="stream">
              <article
                :for={{id, row} <- @streams.metrics}
                id={id}
                class={[
                  "grid gap-4 border-b border-slate-800 px-5 py-5 last:border-b-0 md:grid-cols-[minmax(10rem,1.15fr)_minmax(13rem,2fr)_7rem_minmax(13rem,2fr)] md:items-center md:gap-5 lg:px-6"
                ]}
              >
                <div>
                  <h2 class={["text-sm font-semibold text-slate-100"]}>{row.title}</h2>
                  <p class={["mt-1 font-mono text-[0.65rem] text-slate-500"]}>
                    {row.summary_label} · {row.unit}
                  </p>
                  <div :if={map_size(row.a.lines) > 1} class={["mt-2 flex flex-wrap gap-2"]}>
                    <span
                      :for={key <- line_keys(row.a.lines)}
                      class={["inline-flex items-center gap-1.5 text-[0.65rem] text-slate-500"]}
                    >
                      <span class={[
                        "h-px w-4 border-t border-slate-500",
                        dashed_line?(key) && "border-dashed"
                      ]}>
                      </span>
                      {line_label(key)}
                    </span>
                  </div>
                </div>

                <div class={["grid grid-cols-[minmax(0,1fr)_4.5rem] items-center gap-3"]}>
                  <span class={[
                    "font-mono text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-blue-300 md:hidden"
                  ]}>
                    Run A
                  </span>
                  <span class={["md:hidden"]}></span>
                  <.spark
                    id={"spark-#{row.key}-a"}
                    lines={row.a.lines}
                    all_lines={[row.a.lines, row.b.lines]}
                    max_duration={@comparison.max_duration_seconds}
                    side={:a}
                  />
                  <span class={[
                    "text-right font-mono text-sm font-semibold tabular-nums text-slate-100"
                  ]}>
                    {format_value(row.a.summary)}
                  </span>
                </div>

                <div class={["flex items-center justify-center"]}>
                  <.delta_pill a={row.a.summary} b={row.b.summary} better={row.better} />
                </div>

                <div class={["grid grid-cols-[minmax(0,1fr)_4.5rem] items-center gap-3"]}>
                  <span class={[
                    "font-mono text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-orange-300 md:hidden"
                  ]}>
                    Run B
                  </span>
                  <span class={["md:hidden"]}></span>
                  <.spark
                    id={"spark-#{row.key}-b"}
                    lines={row.b.lines}
                    all_lines={[row.a.lines, row.b.lines]}
                    max_duration={@comparison.max_duration_seconds}
                    side={:b}
                  />
                  <span class={[
                    "text-right font-mono text-sm font-semibold tabular-nums text-slate-100"
                  ]}>
                    {format_value(row.b.summary)}
                  </span>
                </div>
              </article>
            </div>

            <div class={["border-t border-slate-700/80 bg-slate-950/25 px-5 py-3 lg:px-6"]}>
              <h2 class={[
                "font-mono text-[0.62rem] font-semibold uppercase tracking-[0.16em] text-slate-500"
              ]}>
                World workload
              </h2>
            </div>
            <div id="workload-ledger" phx-update="stream">
              <div
                :for={{id, row} <- @streams.workload}
                id={id}
                class={[
                  "grid grid-cols-[minmax(9rem,1fr)_1fr_3rem_1fr] items-center gap-3 border-t border-slate-800 px-5 py-3 text-sm first:border-t-0 lg:grid-cols-[minmax(10rem,1.15fr)_2fr_7rem_2fr] lg:gap-5 lg:px-6"
                ]}
              >
                <span class={["text-slate-400"]}>{row.label}</span>
                <span class={["text-right font-mono font-semibold tabular-nums text-blue-300"]}>
                  {format_value(row.a)}
                </span>
                <span class={["text-center text-slate-700"]}>—</span>
                <span class={["text-right font-mono font-semibold tabular-nums text-orange-300"]}>
                  {format_value(row.b)}
                </span>
              </div>
            </div>
          </section>

          <div class={[
            "mt-4 flex flex-wrap items-center justify-between gap-3 font-mono text-[0.62rem] text-slate-600"
          ]}>
            <span>Every sparkline uses the same elapsed-time width; shorter Runs end early.</span>
            <span>Summary deltas compare B against A.</span>
          </div>
        <% else %>
          <section
            id="run-compare-empty"
            class={[
              "grid min-h-80 place-items-center rounded-2xl border border-dashed border-slate-700 bg-slate-900/40 px-6 text-center"
            ]}
          >
            <div class={["max-w-md"]}>
              <span class={[
                "mx-auto grid size-12 place-items-center rounded-2xl border border-slate-700 bg-slate-950 text-slate-500"
              ]}>
                <.icon name="hero-chart-bar-square" class="size-6" />
              </span>
              <h2 class={["mt-5 text-lg font-semibold text-slate-200"]}>
                Two Runs make a comparison
              </h2>
              <p class={["mt-2 text-sm leading-6 text-slate-500"]}>
                Record at least two observation windows from the World page, then return here to compare them.
              </p>
              <.link
                navigate={~p"/"}
                id="empty-world-link"
                class={[
                  "mt-5 inline-flex items-center gap-2 text-sm font-semibold text-cyan-300 transition hover:text-cyan-200"
                ]}
              >
                Go to World controls <.icon name="hero-arrow-right" class="size-4" />
              </.link>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :side, :atom, required: true

  defp run_chip(assigns) do
    duration = run_duration(assigns.run)
    assigns = assign(assigns, :duration, duration)

    ~H"""
    <div
      id={@id}
      data-run-id={@run.id}
      data-duration-seconds={@duration}
      class={[
        "flex min-w-0 items-center gap-3 rounded-2xl border bg-slate-900/80 px-4 py-3",
        if(@side == :a, do: "border-blue-300/15", else: "border-orange-300/15")
      ]}
    >
      <span class={[
        "grid size-8 shrink-0 place-items-center rounded-xl font-mono text-xs font-bold",
        if(@side == :a, do: "bg-blue-400/10 text-blue-300", else: "bg-orange-400/10 text-orange-300")
      ]}>
        {String.upcase(Atom.to_string(@side))}
      </span>
      <div class={["min-w-0"]}>
        <p class={["truncate text-sm font-semibold text-slate-100"]}>{@run.name}</p>
        <p class={["mt-0.5 truncate font-mono text-[0.62rem] text-slate-500"]}>
          {@run.lane_count} lanes · {format_duration(@duration)} · {format_started_at(@run.started_at)}
        </p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :lines, :map, required: true
  attr :all_lines, :list, required: true
  attr :max_duration, :integer, required: true
  attr :side, :atom, required: true

  defp spark(assigns) do
    max_value = metric_max(assigns.all_lines)
    entries = Enum.map(line_keys(assigns.lines), &%{key: &1, points: assigns.lines[&1]})

    last_offset =
      entries |> Enum.flat_map(& &1.points) |> List.last() |> then(&(&1 && &1.offset_seconds))

    assigns =
      assigns
      |> assign(:entries, entries)
      |> assign(:max_value, max_value)
      |> assign(:last_offset, last_offset)

    ~H"""
    <div
      id={@id}
      data-last-offset={@last_offset}
      class={[
        "relative h-14 min-w-0 overflow-hidden rounded-lg border border-slate-800 bg-slate-950/75"
      ]}
    >
      <svg
        class={["absolute inset-0 size-full"]}
        viewBox="0 0 1000 100"
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <line x1="0" y1="94" x2="1000" y2="94" stroke="rgb(51 65 85 / 0.65)" stroke-width="1" />
        <line x1="0" y1="50" x2="1000" y2="50" stroke="rgb(30 41 59 / 0.8)" stroke-width="1" />
        <polyline
          :for={entry <- @entries}
          points={spark_points(entry.points, @max_duration, @max_value)}
          fill="none"
          stroke={if(@side == :a, do: "#60a5fa", else: "#fb923c")}
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-dasharray={dashed_line?(entry.key) && "7 6"}
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <span
        :if={@entries == []}
        class={[
          "absolute inset-0 grid place-items-center font-mono text-[0.6rem] uppercase tracking-wider text-slate-700"
        ]}
      >
        No samples
      </span>
    </div>
    """
  end

  attr :a, :any, required: true
  attr :b, :any, required: true
  attr :better, :atom, required: true

  defp delta_pill(assigns) do
    {text, class} = delta(assigns.a, assigns.b, assigns.better)
    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={[
      "inline-flex min-w-14 justify-center rounded-full border px-2 py-1 font-mono text-[0.65rem] font-bold tabular-nums",
      @class
    ]}>
      {@text}
    </span>
    """
  end

  defp selected_runs(runs, params) do
    with {:ok, run_a_id} <- parse_id(params["run_a"]),
         {:ok, run_b_id} <- parse_id(params["run_b"]),
         true <- run_a_id != run_b_id,
         %{} = run_a <- Enum.find(runs, &(&1.id == run_a_id)),
         %{} = run_b <- Enum.find(runs, &(&1.id == run_b_id)) do
      {run_a, run_b}
    else
      _ -> default_runs(runs)
    end
  end

  defp default_runs([run_b, run_a | _rest]), do: {run_a, run_b}
  defp default_runs(_runs), do: nil

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error

  defp run_options(runs), do: Enum.map(runs, &{&1.name, Integer.to_string(&1.id)})

  defp line_keys(lines),
    do: for({key, _metadata} <- @line_metadata, Map.has_key?(lines, key), do: key)

  defp dashed_line?(key), do: @line_metadata[key].dashed?
  defp line_label(key), do: @line_metadata[key].label

  defp metric_max(line_maps) do
    values = for lines <- line_maps, {_key, points} <- lines, point <- points, do: point.value
    if values == [], do: 0.0, else: Enum.max(values)
  end

  defp spark_points([], _max_duration, _max_value), do: ""

  defp spark_points(points, max_duration, max_value) do
    Enum.map_join(points, " ", fn point ->
      x = if max_duration > 0, do: point.offset_seconds / max_duration * 1_000, else: 0.0
      y = if max_value > 0, do: 94 - point.value / max_value * 88, else: 94.0
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
  end

  defp delta(a, b, better) when is_number(a) and is_number(b) and a != 0 do
    percent = (b - a) / a * 100
    improved? = (better == :up and percent >= 0) or (better == :down and percent <= 0)
    prefix = if percent > 0, do: "+", else: ""
    text = "#{prefix}#{round(percent)}%"

    class =
      if improved?,
        do: "border-emerald-300/20 bg-emerald-300/5 text-emerald-300",
        else: "border-rose-300/20 bg-rose-300/5 text-rose-300"

    {text, class}
  end

  defp delta(_a, _b, _better), do: {"—", "border-slate-700 bg-slate-950/40 text-slate-600"}

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

  defp run_duration(run), do: DateTime.diff(run.ended_at || DateTime.utc_now(), run.started_at)

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds), do: "#{div(seconds, 60)}m"
  defp format_started_at(started_at), do: Calendar.strftime(started_at, "%b %-d · %H:%M UTC")
end
