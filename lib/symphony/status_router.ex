defmodule Symphony.StatusRouter do
  @moduledoc "Minimal HTTP status surface for operators."

  use Plug.Router
  import Plug.Conn

  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/" do
    body = dashboard_html()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    payload = Symphony.Orchestrator.status()

    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/status/:issue_identifier" do
    case Symphony.Orchestrator.issue_status(issue_identifier) do
      nil ->
        send_resp(conn, 404, "not found")

      payload ->
        body = Jason.encode!(payload)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
    end
  end

  post "/api/v1/refresh" do
    respond_action(conn, Symphony.Orchestrator.refresh())
  end

  post "/api/v1/pause" do
    respond_action(conn, Symphony.Orchestrator.pause())
  end

  post "/api/v1/resume" do
    respond_action(conn, Symphony.Orchestrator.resume())
  end

  post "/api/v1/issues/:issue_identifier/retry" do
    respond_action(conn, Symphony.Orchestrator.retry_issue(issue_identifier))
  end

  post "/api/v1/issues/:issue_identifier/cancel" do
    respond_action(conn, Symphony.Orchestrator.cancel_issue(issue_identifier))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp respond_action(conn, {:ok, payload}) do
    body = Jason.encode!(%{ok: true, payload: payload})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp respond_action(conn, {:error, reason}) do
    body = Jason.encode!(%{ok: false, error: inspect(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, body)
  end

  defp dashboard_html do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Symphony</title>
        <style>
          :root {
            --bg: #f4efe7;
            --panel: #fffaf2;
            --ink: #1d1a17;
            --muted: #6f685f;
            --line: #d8ccbc;
            --accent: #c44f2a;
            --accent-2: #0f7b6c;
            --warn: #a16300;
            --danger: #8f2433;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            font-family: Georgia, "Iowan Old Style", serif;
            color: var(--ink);
            background:
              radial-gradient(circle at top left, rgba(196,79,42,.14), transparent 28%),
              radial-gradient(circle at top right, rgba(15,123,108,.12), transparent 26%),
              linear-gradient(180deg, #f8f3eb 0%, var(--bg) 100%);
          }
          main { max-width: 1400px; margin: 0 auto; padding: 28px; }
          h1, h2, h3 { margin: 0; font-weight: 700; }
          p { margin: 0; }
          .hero {
            display: flex; gap: 18px; align-items: end; justify-content: space-between;
            margin-bottom: 22px; padding: 24px; border: 1px solid var(--line);
            background: rgba(255,250,242,.86); backdrop-filter: blur(8px);
            border-radius: 22px;
          }
          .hero-copy { max-width: 760px; }
          .hero h1 { font-size: 40px; letter-spacing: -0.03em; }
          .hero p { margin-top: 8px; color: var(--muted); font-size: 16px; line-height: 1.4; }
          .actions { display: flex; gap: 10px; flex-wrap: wrap; }
          button {
            border: 1px solid var(--ink); background: var(--ink); color: #fffaf2;
            padding: 10px 14px; border-radius: 999px; cursor: pointer; font: inherit;
          }
          button.secondary { background: transparent; color: var(--ink); }
          button.warn { border-color: var(--warn); color: var(--warn); background: transparent; }
          button.danger { border-color: var(--danger); color: var(--danger); background: transparent; }
          .grid { display: grid; grid-template-columns: 1.2fr 1fr; gap: 18px; }
          .panel {
            background: var(--panel); border: 1px solid var(--line); border-radius: 22px;
            padding: 18px; box-shadow: 0 12px 28px rgba(55, 35, 10, 0.06);
          }
          .stats { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 18px; }
          .stat { padding: 14px; border-radius: 18px; background: #fff; border: 1px solid var(--line); }
          .stat .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
          .stat .value { margin-top: 6px; font-size: 28px; }
          .list { display: grid; gap: 12px; }
          .card {
            border: 1px solid var(--line); border-radius: 18px; padding: 14px;
            background: rgba(255,255,255,.7);
          }
          .card-head { display: flex; justify-content: space-between; gap: 12px; align-items: start; }
          .meta { color: var(--muted); font-size: 13px; line-height: 1.35; margin-top: 6px; }
          .badge {
            display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px;
            border-radius: 999px; font-size: 12px; border: 1px solid var(--line);
            background: #fff;
          }
          .badge.running { border-color: rgba(15,123,108,.35); color: var(--accent-2); }
          .badge.retrying { border-color: rgba(161,99,0,.35); color: var(--warn); }
          .badge.failed { border-color: rgba(143,36,51,.35); color: var(--danger); }
          .badge.completed { border-color: rgba(15,123,108,.35); color: var(--accent-2); }
          .event {
            display: grid; gap: 4px; padding: 12px 0; border-bottom: 1px solid rgba(216,204,188,.6);
          }
          .event:last-child { border-bottom: none; }
          .event-type { font-size: 13px; text-transform: uppercase; letter-spacing: .07em; color: var(--accent); }
          .event-time, .event-details { color: var(--muted); font-size: 13px; line-height: 1.4; }
          pre {
            margin: 8px 0 0; padding: 10px; overflow: auto; white-space: pre-wrap;
            background: #f5ede2; border-radius: 14px; border: 1px solid var(--line);
            font-size: 12px;
          }
          .empty { color: var(--muted); font-style: italic; }
          @media (max-width: 1100px) {
            .grid { grid-template-columns: 1fr; }
            .stats { grid-template-columns: repeat(2, 1fr); }
          }
          @media (max-width: 700px) {
            main { padding: 16px; }
            .hero { flex-direction: column; align-items: stretch; }
            .hero h1 { font-size: 30px; }
            .stats { grid-template-columns: 1fr; }
          }
        </style>
      </head>
      <body>
        <main>
          <section class="hero">
            <div class="hero-copy">
              <h1>Symphony Operator Desk</h1>
              <p>Dispatch state, live issue activity, routing decisions, review handoffs, and manual controls in one place.</p>
            </div>
            <div class="actions">
              <button id="refresh-btn">Refresh now</button>
              <button id="pause-btn" class="secondary">Pause</button>
              <button id="resume-btn" class="secondary">Resume</button>
            </div>
          </section>
          <section class="stats" id="stats"></section>
          <section class="grid">
            <div class="panel">
              <h2>Active Queue</h2>
              <p class="meta" id="queue-meta"></p>
              <div class="list" id="running-list"></div>
              <h2 style="margin-top:18px;">Retry Queue</h2>
              <div class="list" id="retry-list"></div>
              <h2 style="margin-top:18px;">Candidates</h2>
              <div class="list" id="candidate-list"></div>
              <h2 style="margin-top:18px;">Recent Runs</h2>
              <div class="list" id="recent-list"></div>
            </div>
            <div class="panel">
              <h2>Event Timeline</h2>
              <div id="event-list"></div>
            </div>
          </section>
        </main>
        <script>
          const byId = (id) => document.getElementById(id);

          async function getStatus() {
            const res = await fetch('/status');
            return await res.json();
          }

          async function post(path) {
            const res = await fetch(path, { method: 'POST' });
            const text = await res.text();
            let payload = null;
            try { payload = text ? JSON.parse(text) : null; } catch (_) {}
            if (!res.ok) throw new Error(payload?.error || text || 'request failed');
            return payload;
          }

          function fmtTs(ms) {
            if (!ms) return 'n/a';
            return new Date(ms).toLocaleString();
          }

          function esc(value) {
            return String(value ?? '')
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;')
              .replaceAll('"', '&quot;');
          }

          function actionButtons(identifier, running) {
            const retry = `<button class="secondary" data-action="retry" data-issue="${esc(identifier)}">Retry</button>`;
            const cancel = running ? `<button class="danger" data-action="cancel" data-issue="${esc(identifier)}">Cancel</button>` : '';
            return `<div class="actions" style="margin-top:10px;">${retry}${cancel}</div>`;
          }

          function renderStats(status) {
            const items = [
              ['Paused', status.paused ? 'Yes' : 'No'],
              ['Running', status.running_count],
              ['Retries', status.retry_count],
              ['Candidates', status.candidate_count],
              ['Completed', status.completed_count]
            ];
            byId('stats').innerHTML = items.map(([label, value]) => `
              <article class="stat">
                <div class="label">${esc(label)}</div>
                <div class="value">${esc(value)}</div>
              </article>
            `).join('');
            byId('queue-meta').textContent = `Updated ${new Date().toLocaleTimeString()} • poll ${status.poll_interval_ms}ms`;
          }

          function renderCards(targetId, items, mode) {
            const root = byId(targetId);
            if (!items || items.length === 0) {
              root.innerHTML = `<p class="empty">No ${mode}.</p>`;
              return;
            }

            root.innerHTML = items.map((item) => {
              if (mode === 'running') {
                return `
                  <article class="card">
                    <div class="card-head">
                      <div>
                        <strong>${esc(item.identifier)}</strong>
                        <div class="meta">${esc(item.title || '')}</div>
                      </div>
                      <span class="badge running">running</span>
                    </div>
                    <div class="meta">
                      state: ${esc(item.state)}<br/>
                      provider: ${esc(item.routing?.provider || 'n/a')}<br/>
                      model: ${esc(item.routing?.model || 'n/a')}<br/>
                      workspace: ${esc(item.workspace_path || 'n/a')}<br/>
                      session: ${esc(item.session_id || 'n/a')}<br/>
                      tokens: ${esc(item.codex_total_tokens || 0)}<br/>
                      started: ${esc(fmtTs(item.started_at_ms))}
                    </div>
                    ${actionButtons(item.identifier, true)}
                  </article>
                `;
              }

              if (mode === 'retry') {
                return `
                  <article class="card">
                    <div class="card-head">
                      <div>
                        <strong>${esc(item.identifier)}</strong>
                        <div class="meta">attempt ${esc(item.attempt)}</div>
                      </div>
                      <span class="badge retrying">retrying</span>
                    </div>
                    <div class="meta">
                      due: ${esc(fmtTs(item.due_at_ms))}<br/>
                      error: ${esc(item.error || 'n/a')}
                    </div>
                    ${actionButtons(item.identifier, false)}
                  </article>
                `;
              }

              if (mode === 'candidate') {
                return `
                  <article class="card">
                    <div class="card-head">
                      <div>
                        <strong>${esc(item.identifier)}</strong>
                        <div class="meta">${esc(item.title || '')}</div>
                      </div>
                      <span class="badge">${esc(item.state || 'candidate')}</span>
                    </div>
                    <div class="meta">
                      priority: ${esc(item.priority ?? 'n/a')}<br/>
                      branch: ${esc(item.branch_name || 'n/a')}
                    </div>
                  </article>
                `;
              }

              return `
                <article class="card">
                  <div class="card-head">
                    <div>
                      <strong>${esc(item.identifier)}</strong>
                      <div class="meta">${esc(item.issue?.title || '')}</div>
                    </div>
                    <span class="badge ${esc(item.outcome)}">${esc(item.outcome)}</span>
                  </div>
                  <div class="meta">
                    attempt: ${esc(item.attempt)}<br/>
                    completed: ${esc(fmtTs(item.completed_at_ms))}<br/>
                    provider: ${esc(item.routing?.provider || 'n/a')}<br/>
                    model: ${esc(item.routing?.model || 'n/a')}<br/>
                    error: ${esc(item.error || 'none')}
                  </div>
                  ${item.artifacts?.length ? `<pre>${esc(JSON.stringify(item.artifacts, null, 2))}</pre>` : ''}
                  ${actionButtons(item.identifier, false)}
                </article>
              `;
            }).join('');
          }

          function renderEvents(events) {
            const root = byId('event-list');
            if (!events || events.length === 0) {
              root.innerHTML = '<p class="empty">No events yet.</p>';
              return;
            }
            root.innerHTML = events.map((event) => `
              <article class="event">
                <div class="event-type">${esc(event.type)}</div>
                <div class="event-time">${esc(fmtTs(event.timestamp_ms))}${event.issue_identifier ? ` • ${esc(event.issue_identifier)}` : ''}</div>
                <div class="event-details">${esc(JSON.stringify(event.details || {}))}</div>
              </article>
            `).join('');
          }

          async function render() {
            const status = await getStatus();
            renderStats(status);
            renderCards('running-list', status.running, 'running');
            renderCards('retry-list', status.retries, 'retry');
            renderCards('candidate-list', status.candidates, 'candidate');
            renderCards('recent-list', status.recent_runs, 'recent');
            renderEvents(status.events);
          }

          document.addEventListener('click', async (event) => {
            const button = event.target.closest('button[data-action]');
            if (!button) return;
            const issue = button.getAttribute('data-issue');
            const action = button.getAttribute('data-action');
            const path = action === 'retry'
              ? `/api/v1/issues/${encodeURIComponent(issue)}/retry`
              : `/api/v1/issues/${encodeURIComponent(issue)}/cancel`;
            await post(path);
            await render();
          });

          byId('refresh-btn').addEventListener('click', async () => { await post('/api/v1/refresh'); await render(); });
          byId('pause-btn').addEventListener('click', async () => { await post('/api/v1/pause'); await render(); });
          byId('resume-btn').addEventListener('click', async () => { await post('/api/v1/resume'); await render(); });

          render().catch((error) => console.error(error));
          setInterval(() => { render().catch(() => {}); }, 4000);
        </script>
      </body>
    </html>
    """
  end
end
