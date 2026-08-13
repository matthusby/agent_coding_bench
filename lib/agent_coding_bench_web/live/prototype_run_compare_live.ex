defmodule AgentCodingBenchWeb.PrototypeRunCompareLive do
  @moduledoc """
  PROTOTYPE — throwaway, do not build on. Wayfinder ticket #11.

  Three variants of the Run overlay/comparison dashboard on
  `/prototype/run-compare` (dev-only route), switchable via `?variant=a|b|c`
  or the floating bottom bar (arrow keys work too). All data is fake:
  two Runs, "baseline-8" (8 lanes, 42 min) vs "push-16" (16 lanes, 38 min),
  aligned on offset-from-start per the metrics-and-runs decision (#6).

    a — Stacked strips: charts first, both runs overlaid on shared axes
    b — Ledger: one metric per row, A | delta | B, judgment row by row
    c — Cockpit: KPI tiles first, one focus chart, detail on demand
  """
  use AgentCodingBenchWeb, :live_view

  @variants ~w(a b c)
  @variant_names %{"a" => "Stacked strips", "b" => "Ledger", "c" => "Cockpit"}

  @n 85
  @dur_a 42 * 60
  @dur_b 38 * 60

  @impl true
  def mount(_params, _session, socket) do
    s = fake_series()

    {:ok,
     assign(socket,
       page_title: "Run compare — prototype",
       charts: charts(s),
       stats: stats(s),
       calls: fake_calls(),
       workload: fake_workload(),
       runs: fake_runs(),
       focus: :toks
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    variant = if params["variant"] in @variants, do: params["variant"], else: "a"
    {:noreply, assign(socket, variant: variant)}
  end

  @impl true
  def handle_event("cycle", %{"key" => key}, socket) when key in ~w(ArrowLeft ArrowRight) do
    step = if key == "ArrowRight", do: 1, else: -1
    idx = Enum.find_index(@variants, &(&1 == socket.assigns.variant))
    next = Enum.at(@variants, rem(idx + step + 3, 3))
    {:noreply, push_patch(socket, to: ~p"/prototype/run-compare?variant=#{next}")}
  end

  def handle_event("cycle", _params, socket), do: {:noreply, socket}

  def handle_event("focus", %{"metric" => m}, socket) do
    focus =
      Enum.find_value(socket.assigns.charts, socket.assigns.focus, fn c ->
        if Atom.to_string(c.key) == m, do: c.key
      end)

    {:noreply, assign(socket, focus: focus)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="run-compare-proto"
        class="w-[min(88rem,calc(100vw-3rem))] relative left-1/2 -translate-x-1/2 pb-24"
        phx-window-keydown="cycle"
      >
        <style phx-no-curly-interpolation>
          #run-compare-proto {
            --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
            --grid: #e1e0d9; --axis: #c3c2b7; --hairline: rgba(11, 11, 11, 0.10);
            --run-a: #2a78d6; --run-b: #eb6834;
            --good: #006300; --bad: #d03b3b;
          }
          [data-theme="dark"] #run-compare-proto {
            --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7;
            --grid: #2c2c2a; --axis: #383835; --hairline: rgba(255, 255, 255, 0.10);
            --run-a: #3987e5; --run-b: #d95926;
            --good: #0ca30c; --bad: #e66767;
          }
          @media (prefers-color-scheme: dark) {
            [data-theme="system"] #run-compare-proto, :root:not([data-theme]) #run-compare-proto {
              --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7;
              --grid: #2c2c2a; --axis: #383835; --hairline: rgba(255, 255, 255, 0.10);
              --run-a: #3987e5; --run-b: #d95926;
              --good: #0ca30c; --bad: #e66767;
            }
          }
        </style>

        <%= case @variant do %>
          <% "a" -> %>
            <.variant_a charts={@charts} calls={@calls} workload={@workload} runs={@runs} />
          <% "b" -> %>
            <.variant_b charts={@charts} workload={@workload} runs={@runs} />
          <% "c" -> %>
            <.variant_c
              charts={@charts}
              stats={@stats}
              calls={@calls}
              workload={@workload}
              runs={@runs}
              focus={@focus}
            />
        <% end %>

        <.switcher variant={@variant} />
      </div>
    </Layouts.app>
    """
  end

  ## Variant A — Stacked strips: charts first, overlay on shared axes

  attr :charts, :list, required: true
  attr :calls, :list, required: true
  attr :workload, :list, required: true
  attr :runs, :map, required: true

  defp variant_a(assigns) do
    ~H"""
    <div class="space-y-8" style="color: var(--ink);">
      <.compare_header runs={@runs}>
        Charts first — everything overlaid on shared axes, aligned on offset from run start.
      </.compare_header>

      <section class="space-y-6">
        <.strip_chart :for={c <- @charts} chart={c} />
      </section>

      <section class="space-y-3">
        <h2 class="text-base font-semibold">Calls &amp; workload</h2>
        <div class="flex flex-wrap gap-x-8 gap-y-2 text-sm">
          <div :for={w <- @workload} class="flex items-baseline gap-2">
            <span style="color: var(--ink-2);">{w.label}</span>
            <span class="flex items-center gap-1 tabular-nums font-medium">
              <.run_dot run={:a} />{w.a}
            </span>
            <span class="flex items-center gap-1 tabular-nums font-medium">
              <.run_dot run={:b} />{w.b}
            </span>
          </div>
        </div>
        <.calls_table calls={@calls} runs={@runs} />
      </section>
    </div>
    """
  end

  ## Variant B — Ledger: one metric per row, A | delta | B

  attr :charts, :list, required: true
  attr :workload, :list, required: true
  attr :runs, :map, required: true

  defp variant_b(assigns) do
    ~H"""
    <div class="space-y-6" style="color: var(--ink);">
      <.compare_header runs={@runs}>
        One metric per row — A and B juxtaposed with an explicit delta, judged row by row.
      </.compare_header>

      <div class="rounded-xl overflow-hidden" style="border: 1px solid var(--hairline);">
        <div
          class="grid grid-cols-[minmax(11rem,1.1fr)_2fr_7rem_2fr] items-center gap-4 px-4 py-2 text-xs font-medium"
          style="color: var(--ink-2); border-bottom: 1px solid var(--hairline);"
        >
          <span>Metric</span>
          <span class="flex items-center gap-1.5"><.run_dot run={:a} /> {@runs.a.name}</span>
          <span class="text-center">Δ B vs A</span>
          <span class="flex items-center gap-1.5"><.run_dot run={:b} /> {@runs.b.name}</span>
        </div>

        <div
          :for={c <- @charts}
          class="grid grid-cols-[minmax(11rem,1.1fr)_2fr_7rem_2fr] items-center gap-4 px-4 py-3"
          style="border-bottom: 1px solid var(--hairline);"
        >
          <div>
            <div class="text-sm font-medium">{c.title}</div>
            <div class="text-xs" style="color: var(--muted);">{c.sum_label} · {c.unit}</div>
          </div>
          <div class="flex items-center gap-3">
            <.spark lines={run_lines(c, :a)} />
            <span class="tabular-nums text-sm font-semibold w-16 text-right">{fmt(c.sum_a)}</span>
          </div>
          <div class="text-center">
            <.delta_pill a={c.sum_a} b={c.sum_b} good={c.good} />
          </div>
          <div class="flex items-center gap-3">
            <.spark lines={run_lines(c, :b)} />
            <span class="tabular-nums text-sm font-semibold w-16 text-right">{fmt(c.sum_b)}</span>
          </div>
        </div>

        <div
          :for={w <- @workload}
          class="grid grid-cols-[minmax(11rem,1.1fr)_2fr_7rem_2fr] items-center gap-4 px-4 py-2"
          style="border-bottom: 1px solid var(--hairline);"
        >
          <div class="text-sm" style="color: var(--ink-2);">{w.label}</div>
          <div class="tabular-nums text-sm font-medium text-right pr-0">{w.a}</div>
          <div class="text-center text-xs" style="color: var(--muted);">—</div>
          <div class="tabular-nums text-sm font-medium text-right pr-0">{w.b}</div>
        </div>
      </div>

      <p class="text-xs" style="color: var(--muted);">
        Sparklines share the offset axis: {@runs.b.name} is shorter, so its line ends early.
      </p>
    </div>
    """
  end

  ## Variant C — Cockpit: KPI tiles, one focus chart, detail on demand

  attr :charts, :list, required: true
  attr :stats, :list, required: true
  attr :calls, :list, required: true
  attr :workload, :list, required: true
  attr :runs, :map, required: true
  attr :focus, :atom, required: true

  defp variant_c(assigns) do
    ~H"""
    <div class="space-y-6" style="color: var(--ink);">
      <.compare_header runs={@runs}>
        Numbers first — headline KPIs, one focus chart, detail on demand.
      </.compare_header>

      <section class="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3">
        <div
          :for={st <- @stats}
          class="rounded-xl p-3"
          style="border: 1px solid var(--hairline); background: var(--surface);"
        >
          <div class="text-xs" style="color: var(--ink-2);">{st.title}</div>
          <div class="mt-1.5 space-y-0.5">
            <div class="flex items-center gap-1.5 text-lg font-semibold tabular-nums leading-tight">
              <.run_dot run={:a} />{fmt(st.a)}<span
                class="text-xs font-normal"
                style="color: var(--muted);"
              >{st.unit}</span>
            </div>
            <div class="flex items-center gap-1.5 text-lg font-semibold tabular-nums leading-tight">
              <.run_dot run={:b} />{fmt(st.b)}<span
                class="text-xs font-normal"
                style="color: var(--muted);"
              >{st.unit}</span>
            </div>
          </div>
          <div class="mt-1.5"><.delta_pill a={st.a} b={st.b} good={st.good} /></div>
        </div>
      </section>

      <section class="grid lg:grid-cols-[1fr_15rem] gap-4">
        <.strip_chart chart={Enum.find(@charts, &(&1.key == @focus))} h="h-80" />
        <aside class="space-y-2">
          <div class="text-xs font-medium" style="color: var(--ink-2);">Focus a metric</div>
          <button
            :for={c <- @charts}
            id={"focus-#{c.key}"}
            phx-click="focus"
            phx-value-metric={c.key}
            class={[
              "w-full text-left rounded-lg p-2 transition-opacity cursor-pointer",
              c.key != @focus && "opacity-60 hover:opacity-100"
            ]}
            style={"border: 1px solid var(--hairline); #{if c.key == @focus, do: "background: var(--surface); outline: 2px solid var(--axis);"}"}
          >
            <div class="text-xs mb-1">{c.title}</div>
            <.spark lines={c.lines} h="h-8" />
          </button>
        </aside>
      </section>

      <section class="grid md:grid-cols-[2fr_1fr] gap-4 items-start">
        <div class="space-y-2">
          <h2 class="text-sm font-semibold">Calls by role</h2>
          <.calls_table calls={@calls} runs={@runs} />
        </div>
        <div class="rounded-xl p-4 space-y-2" style="border: 1px solid var(--hairline);">
          <h2 class="text-sm font-semibold">Workload</h2>
          <div
            :for={w <- @workload}
            class="flex items-center justify-between text-sm py-1"
            style="border-bottom: 1px solid var(--hairline);"
          >
            <span style="color: var(--ink-2);">{w.label}</span>
            <span class="flex items-center gap-3 tabular-nums font-medium">
              <span class="flex items-center gap-1"><.run_dot run={:a} />{w.a}</span>
              <span class="flex items-center gap-1"><.run_dot run={:b} />{w.b}</span>
            </span>
          </div>
        </div>
      </section>
    </div>
    """
  end

  ## Shared pieces

  attr :runs, :map, required: true
  slot :inner_block, required: true

  defp compare_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-xl font-semibold">Run comparison</h1>
        <p class="text-sm" style="color: var(--ink-2);">{render_slot(@inner_block)}</p>
      </div>
      <div class="flex items-center gap-3 flex-wrap">
        <.run_chip run={:a} meta={@runs.a} />
        <span class="text-sm" style="color: var(--muted);">vs</span>
        <.run_chip run={:b} meta={@runs.b} />
        <span
          :if={@runs.a.digest == @runs.b.digest}
          class="flex items-center gap-1 text-xs font-medium"
          style="color: var(--good);"
        >
          <.icon name="hero-check-circle-micro" class="size-4" /> config match · fp {@runs.a.digest}
        </span>
      </div>
    </header>
    """
  end

  attr :run, :atom, required: true
  attr :meta, :map, required: true

  defp run_chip(assigns) do
    ~H"""
    <div
      class="flex items-center gap-2 rounded-full px-3 py-1.5"
      style="border: 1px solid var(--hairline);"
    >
      <.run_dot run={@run} />
      <span class="text-sm font-semibold">{@meta.name}</span>
      <span class="text-xs" style="color: var(--ink-2);">
        {@meta.lanes} lanes · {@meta.dur} · started {@meta.started}
      </span>
    </div>
    """
  end

  attr :run, :atom, required: true

  defp run_dot(assigns) do
    ~H"""
    <span class="size-2.5 rounded-full shrink-0" style={"background: #{run_color(@run)};"}></span>
    """
  end

  attr :chart, :map, required: true
  attr :h, :string, default: "h-44"

  defp strip_chart(assigns) do
    ~H"""
    <div>
      <div class="flex items-baseline justify-between mb-1">
        <h3 class="text-sm font-medium">
          {@chart.title} <span class="text-xs" style="color: var(--muted);">{@chart.unit}</span>
        </h3>
        <div class="flex items-center gap-3 text-xs" style="color: var(--ink-2);">
          <span :for={l <- @chart.lines} class="flex items-center gap-1.5">
            <svg width="18" height="6" aria-hidden="true">
              <line
                x1="0"
                y1="3"
                x2="18"
                y2="3"
                stroke={run_color(l.run)}
                stroke-width="2"
                stroke-dasharray={l.dash && "4 3"}
              />
            </svg>
            {l.label}
          </span>
        </div>
      </div>
      <div
        class={["relative rounded-lg", @h]}
        style="background: var(--surface); border: 1px solid var(--hairline);"
      >
        <svg class="absolute inset-0 w-full h-full" viewBox="0 0 1000 100" preserveAspectRatio="none">
          <line
            :for={y <- [27, 50, 73]}
            x1="0"
            y1={y}
            x2="1000"
            y2={y}
            stroke="var(--grid)"
            stroke-width="1"
            vector-effect="non-scaling-stroke"
          />
          <line
            x1="0"
            y1="96"
            x2="1000"
            y2="96"
            stroke="var(--axis)"
            stroke-width="1"
            vector-effect="non-scaling-stroke"
          />
          <polyline
            :for={l <- @chart.lines}
            points={l.poly}
            fill="none"
            stroke={run_color(l.run)}
            stroke-width="2"
            stroke-linejoin="round"
            stroke-dasharray={l.dash && "6 5"}
            vector-effect="non-scaling-stroke"
          />
          <rect
            :for={hc <- @chart.hover}
            x={hc.x}
            y="0"
            width="25"
            height="100"
            fill="transparent"
            class="hover:fill-[rgba(128,128,128,0.10)]"
          >
            <title>{hc.title}</title>
          </rect>
        </svg>
        <span class="absolute top-1 left-2 text-[10px] tabular-nums" style="color: var(--muted);">
          {fmt(@chart.ymax)}
        </span>
        <span class="absolute bottom-1 left-2 text-[10px]" style="color: var(--muted);">0</span>
      </div>
      <div class="flex justify-between text-[10px] mt-0.5 tabular-nums" style="color: var(--muted);">
        <span>t+0</span><span>t+10m</span><span>t+21m</span><span>t+31m</span><span>t+42m</span>
      </div>
    </div>
    """
  end

  attr :lines, :list, required: true
  attr :h, :string, default: "h-12"

  defp spark(assigns) do
    ~H"""
    <div
      class={["relative rounded flex-1", @h]}
      style="background: var(--surface); border: 1px solid var(--hairline);"
    >
      <svg class="absolute inset-0 w-full h-full" viewBox="0 0 1000 100" preserveAspectRatio="none">
        <polyline
          :for={l <- @lines}
          points={l.poly}
          fill="none"
          stroke={run_color(l.run)}
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-dasharray={l.dash && "5 4"}
          vector-effect="non-scaling-stroke"
        />
      </svg>
    </div>
    """
  end

  attr :a, :any, required: true
  attr :b, :any, required: true
  attr :good, :atom, required: true

  defp delta_pill(assigns) do
    d = (assigns.b - assigns.a) / assigns.a * 100

    color =
      case {assigns.good, d >= 0} do
        {:up, true} -> "var(--good)"
        {:up, false} -> "var(--bad)"
        {:down, true} -> "var(--bad)"
        {:down, false} -> "var(--good)"
      end

    assigns = assign(assigns, txt: "#{if d >= 0, do: "+"}#{round(d)}%", color: color)

    ~H"""
    <span
      class="inline-block rounded-full px-2 py-0.5 text-xs font-semibold tabular-nums"
      style={"color: #{@color}; border: 1px solid var(--hairline);"}
    >
      {@txt}
    </span>
    """
  end

  attr :calls, :list, required: true
  attr :runs, :map, required: true

  defp calls_table(assigns) do
    ~H"""
    <div class="rounded-xl overflow-hidden" style="border: 1px solid var(--hairline);">
      <table class="w-full text-sm">
        <thead>
          <tr class="text-xs text-left" style="color: var(--ink-2);">
            <th class="px-3 py-2 font-medium">Role</th>
            <th class="px-3 py-2 font-medium">Run</th>
            <th class="px-3 py-2 font-medium text-right">Calls</th>
            <th class="px-3 py-2 font-medium text-right">Prompt tok</th>
            <th class="px-3 py-2 font-medium text-right">Output tok</th>
            <th class="px-3 py-2 font-medium text-right">Cached</th>
            <th class="px-3 py-2 font-medium text-right">TTFT (client)</th>
            <th class="px-3 py-2 font-medium text-right">Mean dur</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @calls, {run, c} <- [{:a, row.a}, {:b, row.b}] do %>
            <tr class="tabular-nums" style="border-top: 1px solid var(--hairline);">
              <td class="px-3 py-1.5 font-medium">{if run == :a, do: row.role}</td>
              <td class="px-3 py-1.5">
                <span class="flex items-center gap-1.5 text-xs" style="color: var(--ink-2);">
                  <.run_dot run={run} />{run_name(@runs, run)}
                </span>
              </td>
              <td class="px-3 py-1.5 text-right">{c.calls}</td>
              <td class="px-3 py-1.5 text-right">{fmt_tok(c.tok_in)}</td>
              <td class="px-3 py-1.5 text-right">{fmt_tok(c.tok_out)}</td>
              <td class="px-3 py-1.5 text-right">{c.cached}%</td>
              <td class="px-3 py-1.5 text-right">{if c.ttft, do: "#{c.ttft} ms", else: "—"}</td>
              <td class="px-3 py-1.5 text-right">{c.dur} s</td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <p class="px-3 py-2 text-xs" style="color: var(--muted); border-top: 1px solid var(--hairline);">
        Coder TTFT is serving-side only (opencode messages carry no client TTFT) — see the TTFT chart.
      </p>
    </div>
    """
  end

  attr :variant, :string, required: true

  defp switcher(assigns) do
    idx = Enum.find_index(@variants, &(&1 == assigns.variant))
    prev = Enum.at(@variants, rem(idx + 2, 3))
    next = Enum.at(@variants, rem(idx + 1, 3))
    assigns = assign(assigns, prev: prev, next: next, name: @variant_names[assigns.variant])

    ~H"""
    <div
      id="proto-switcher"
      class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 flex items-center gap-3 rounded-full bg-neutral-900 text-white px-4 py-2 shadow-lg border border-white/20"
    >
      <span class="text-[10px] uppercase tracking-widest opacity-60">prototype</span>
      <.link
        patch={~p"/prototype/run-compare?variant=#{@prev}"}
        class="px-1 text-lg leading-none hover:opacity-70"
        aria-label="Previous variant"
      >
        &larr;
      </.link>
      <span class="text-sm font-medium min-w-40 text-center">
        {String.upcase(@variant)} — {@name}
      </span>
      <.link
        patch={~p"/prototype/run-compare?variant=#{@next}"}
        class="px-1 text-lg leading-none hover:opacity-70"
        aria-label="Next variant"
      >
        &rarr;
      </.link>
    </div>
    """
  end

  defp run_color(:a), do: "var(--run-a)"
  defp run_color(:b), do: "var(--run-b)"

  defp run_name(runs, run), do: runs[run].name

  defp run_lines(chart, run), do: Enum.filter(chart.lines, &(&1.run == run))

  ## Fake data — two runs' worth of plausible serving metrics

  defp fake_runs do
    %{
      a: %{name: "baseline-8", lanes: 8, dur: "42 min", digest: "3f2c9ab4", started: "14:02"},
      b: %{name: "push-16", lanes: 16, dur: "38 min", digest: "3f2c9ab4", started: "15:07"}
    }
  end

  defp fake_series do
    %{
      toks: %{
        a: gen(:toks_a, fn t, z -> warm(t) * (1350 + 120 * :math.sin(t * 9) + 180 * z) end),
        b:
          gen(:toks_b, fn t, z ->
            warm(t) * (2180 + 240 * :math.sin(t * 7 + 1) + 300 * z - 520 * bump(t, 0.55, 0.03))
          end)
      },
      ttft: %{
        a50: gen(:ta5, fn t, z -> 0.42 + 0.05 * :math.sin(t * 6) + 0.08 * z end),
        a99: gen(:ta9, fn t, z -> 1.8 + 0.35 * :math.sin(t * 5 + 2) + 0.5 * z end),
        b50:
          gen(:tb5, fn t, z ->
            0.95 + 0.15 * :math.sin(t * 6 + 1) + 0.2 * z + 0.5 * bump(t, 0.55, 0.05)
          end),
        b99:
          gen(:tb9, fn t, z ->
            5.1 + 1.1 * :math.sin(t * 5) + 1.4 * z + 3.2 * bump(t, 0.55, 0.05)
          end)
      },
      itl: %{
        a50: gen(:ia5, fn t, z -> 28 + 2.5 * :math.sin(t * 8) + 3 * z end),
        a99: gen(:ia9, fn t, z -> 61 + 6 * :math.sin(t * 7) + 9 * z end),
        b50: gen(:ib5, fn t, z -> 46 + 5 * :math.sin(t * 8 + 2) + 6 * z end),
        b99:
          gen(:ib9, fn t, z -> 112 + 14 * :math.sin(t * 6) + 18 * z + 40 * bump(t, 0.55, 0.05) end)
      },
      reqs: %{
        a_run:
          gen(:ra, fn t, z -> warm(t) * min(7.5 + 0.9 * z + 0.4 * :math.sin(t * 11), 8.0) end),
        a_wait: gen(:wa, fn t, z -> max(0.3 + 0.8 * z + 0.4 * :math.sin(t * 13), 0.0) end),
        b_run:
          gen(:rb, fn t, z -> warm(t) * min(15.2 + 1.2 * z + 0.6 * :math.sin(t * 10), 16.0) end),
        b_wait:
          gen(:wb, fn t, z ->
            max(1.4 + 2.4 * z + 1.1 * :math.sin(t * 13) + 6.5 * bump(t, 0.55, 0.05), 0.0)
          end)
      },
      kv: %{
        a: gen(:ka, fn t, z -> warm(t) * (53 + 5 * :math.sin(t * 4) + 3 * z) end),
        b:
          gen(:kb, fn t, z ->
            warm(t) * min(79 + 7 * :math.sin(t * 3 + 1) + 4 * z + 11 * bump(t, 0.55, 0.06), 97.0)
          end)
      }
    }
  end

  defp charts(s) do
    fb = @dur_b / @dur_a

    [
      chart(:toks, "Generation throughput", "tok/s", :up, "median", &med/1, [
        line(:a, "A", false, s.toks.a, 1.0),
        line(:b, "B", false, s.toks.b, fb)
      ]),
      chart(:ttft, "Time to first token", "s", :down, "median p99", &med/1, [
        line(:a, "A p50", false, s.ttft.a50, 1.0),
        line(:a, "A p99", true, s.ttft.a99, 1.0),
        line(:b, "B p50", false, s.ttft.b50, fb),
        line(:b, "B p99", true, s.ttft.b99, fb)
      ]),
      chart(:itl, "Inter-token latency", "ms", :down, "median p99", &med/1, [
        line(:a, "A p50", false, s.itl.a50, 1.0),
        line(:a, "A p99", true, s.itl.a99, 1.0),
        line(:b, "B p50", false, s.itl.b50, fb),
        line(:b, "B p99", true, s.itl.b99, fb)
      ]),
      chart(:reqs, "Requests running / waiting", "reqs", :down, "peak waiting", &Enum.max/1, [
        line(:a, "A running", false, s.reqs.a_run, 1.0),
        line(:a, "A waiting", true, s.reqs.a_wait, 1.0),
        line(:b, "B running", false, s.reqs.b_run, fb),
        line(:b, "B waiting", true, s.reqs.b_wait, fb)
      ]),
      chart(:kv, "KV-cache usage", "%", :down, "peak", &Enum.max/1, [
        line(:a, "A", false, s.kv.a, 1.0),
        line(:b, "B", false, s.kv.b, fb)
      ])
    ]
  end

  defp line(run, label, dash, pts, frac),
    do: %{run: run, label: label, dash: dash, pts: pts, frac: frac}

  defp chart(key, title, unit, good, sum_label, sum_fun, lines) do
    ymax = lines |> Enum.flat_map(& &1.pts) |> Enum.max() |> Kernel.*(1.08)
    lines = Enum.map(lines, &Map.put(&1, :poly, poly(&1.pts, &1.frac, ymax)))

    # summary compares the last (dashed p99 / waiting) or only line of each run
    sum = fn run ->
      lines |> Enum.filter(&(&1.run == run)) |> List.last() |> then(&sum_fun.(steady(&1.pts)))
    end

    %{
      key: key,
      title: title,
      unit: unit,
      good: good,
      ymax: ymax,
      lines: lines,
      hover: hover(lines, unit),
      sum_label: sum_label,
      sum_a: sum.(:a),
      sum_b: sum.(:b)
    }
  end

  defp poly(pts, frac, ymax) do
    n = length(pts)

    pts
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      x = Float.round(i / (n - 1) * frac * 1000, 1)
      y = Float.round(100 - v / ymax * 92 - 4, 1)
      "#{x},#{y}"
    end)
  end

  defp hover(lines, unit) do
    for b <- 0..39 do
      tfrac = (b + 0.5) / 40
      secs = round(tfrac * @dur_a)

      vals =
        for l <- lines, tfrac <= l.frac do
          idx = min(round(tfrac / l.frac * (@n - 1)), @n - 1)
          "#{l.label}: #{fmt(Enum.at(l.pts, idx))} #{unit}"
        end

      %{x: Float.round(b / 40 * 1000, 1), title: Enum.join(["t+#{mmss(secs)}" | vals], "\n")}
    end
  end

  defp stats(s) do
    [
      %{
        title: "Median tok/s",
        unit: "",
        good: :up,
        a: med(steady(s.toks.a)),
        b: med(steady(s.toks.b))
      },
      %{title: "p99 TTFT", unit: "s", good: :down, a: med(s.ttft.a99), b: med(s.ttft.b99)},
      %{title: "p50 ITL", unit: "ms", good: :down, a: med(s.itl.a50), b: med(s.itl.b50)},
      %{
        title: "Peak waiting",
        unit: "reqs",
        good: :down,
        a: Enum.max(s.reqs.a_wait),
        b: Enum.max(s.reqs.b_wait)
      },
      %{title: "Peak KV cache", unit: "%", good: :down, a: Enum.max(s.kv.a), b: Enum.max(s.kv.b)},
      %{title: "Tasks / hour", unit: "", good: :up, a: 25.7, b: 46.4}
    ]
  end

  defp fake_calls do
    [
      %{
        role: "PM",
        a: %{calls: 31, tok_in: 58_400, tok_out: 9_100, cached: 34, ttft: 410, dur: 6.1},
        b: %{calls: 54, tok_in: 101_700, tok_out: 15_800, cached: 31, ttft: 930, dur: 9.4}
      },
      %{
        role: "Coder",
        a: %{calls: 214, tok_in: 1_842_000, tok_out: 96_300, cached: 61, ttft: nil, dur: 21.4},
        b: %{calls: 388, tok_in: 3_390_000, tok_out: 171_500, cached: 58, ttft: nil, dur: 34.8}
      },
      %{
        role: "Reviewer",
        a: %{calls: 24, tok_in: 96_200, tok_out: 18_400, cached: 12, ttft: 480, dur: 11.2},
        b: %{calls: 41, tok_in: 168_900, tok_out: 30_100, cached: 11, ttft: 1_050, dur: 17.6}
      },
      %{
        role: "Person",
        a: %{calls: 58, tok_in: 74_800, tok_out: 6_900, cached: 42, ttft: 390, dur: 3.2},
        b: %{calls: 97, tok_in: 129_300, tok_out: 11_600, cached: 40, ttft: 870, dur: 5.1}
      }
    ]
  end

  defp fake_workload do
    [
      %{label: "Tasks started", a: "31", b: "54"},
      %{label: "Merged", a: "18", b: "27"},
      %{label: "Abandoned", a: "3", b: "9"},
      %{label: "Tasks / hour", a: "25.7", b: "46.4"},
      %{label: "Review cycles / task", a: "1.4", b: "1.9"},
      %{label: "Coder turns / task", a: "6.9", b: "7.2"}
    ]
  end

  ## Series generation — deterministic pseudo-noise, no randomness

  defp gen(seed, fun) do
    for i <- 0..(@n - 1) do
      t = i / (@n - 1)
      z = :erlang.phash2({seed, i}, 1000) / 1000 - 0.5
      Float.round(max(fun.(t, z) * 1.0, 0.0), 2)
    end
  end

  defp bump(t, c, w), do: :math.exp(-1 * (t - c) * (t - c) / (2 * w * w))
  defp warm(t), do: min(t * 18, 1.0)

  # drop the warmup ramp so medians reflect steady state
  defp steady(pts), do: Enum.drop(pts, div(@n, 10))

  defp med(pts), do: pts |> Enum.sort() |> Enum.at(div(length(pts), 2))

  defp mmss(secs), do: "#{div(secs, 60)}:#{String.pad_leading("#{rem(secs, 60)}", 2, "0")}"

  defp fmt(v) when is_float(v) do
    cond do
      v >= 1000 -> comma(round(v))
      v >= 10 -> "#{round(v)}"
      true -> :erlang.float_to_binary(v, decimals: 2)
    end
  end

  defp fmt(v) when is_integer(v), do: comma(v)

  defp comma(n) when n < 1000, do: Integer.to_string(n)

  defp comma(n),
    do: comma(div(n, 1000)) <> "," <> String.pad_leading(Integer.to_string(rem(n, 1000)), 3, "0")

  defp fmt_tok(n) when n >= 1_000_000,
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 2) <> "M"

  defp fmt_tok(n) when n >= 1_000, do: :erlang.float_to_binary(n / 1_000, decimals: 1) <> "k"
  defp fmt_tok(n), do: Integer.to_string(n)
end
