defmodule AgentCodingBenchWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AgentCodingBenchWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={["min-h-screen bg-slate-950 text-slate-100"]}>
      <header class={["border-b border-slate-800/80 bg-slate-950/90"]}>
        <div class={["mx-auto flex h-16 max-w-7xl items-center justify-between px-5 sm:px-8"]}>
          <a href={~p"/"} class={["group flex items-center gap-3"]}>
            <span class={[
              "grid size-9 place-items-center rounded-xl border border-cyan-300/20 bg-cyan-300/10 text-cyan-300 shadow-inner shadow-cyan-200/5 transition group-hover:border-cyan-300/40 group-hover:bg-cyan-300/15"
            ]}>
              <.icon name="hero-command-line-solid" class="size-5" />
            </span>
            <span>
              <span class={["block text-sm font-semibold tracking-tight text-slate-100"]}>
                Agent Coding Bench
              </span>
              <span class={[
                "block font-mono text-[0.58rem] uppercase tracking-[0.2em] text-slate-500"
              ]}>
                MI300X observatory
              </span>
            </span>
          </a>

          <div class={["flex items-center gap-3"]}>
            <span class={[
              "rounded-full border border-slate-800 bg-slate-900 px-3 py-1.5 font-mono text-[0.62rem] font-medium tracking-[0.12em] text-slate-500"
            ]}>
              LOCAL CONTROL
            </span>
          </div>
        </div>
      </header>

      <main>
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
