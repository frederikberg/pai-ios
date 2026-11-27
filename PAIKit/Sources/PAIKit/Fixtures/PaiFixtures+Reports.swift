import Foundation

/// The Reports app: the list, one report with a stored answer, and a page that speaks the host
/// protocol (`ReportProtocol`) — it asks for `init`, reports its answers and has an Add to message
/// button — so the screenshot workflow photographs the web view and the bridge works end to end.
extension PaiFixtures {

    /// The report every fixture report route answers under, whatever id is asked for.
    public static let reportFixtureID = "5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77"

    public static let dynamicReports = #"""
        {
          "reports": [
            {
              "id": "5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77",
              "title": "Launch plan: three decisions",
              "session_id": "2c0f7a10-6f1e-4b0a-9a53-1f6f2d8d9a01",
              "session_title": "Launch planning",
              "url": "https://pai.example.invalid/apps/reports/5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77",
              "answers": {"d1": "Option B"},
              "created_at": "2026-11-26T18:30:00+00:00",
              "updated_at": "2026-11-26T18:45:00+00:00"
            },
            {
              "id": "5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d78",
              "title": "Cost comparison",
              "session_id": null,
              "session_title": null,
              "url": "https://pai.example.invalid/apps/reports/5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d78",
              "answers": {},
              "created_at": "2026-11-20T09:00:00+00:00",
              "updated_at": "2026-11-20T09:00:00+00:00"
            }
          ]
        }
        """#

    public static let dynamicReportDetail = #"""
        {
          "report": {
            "id": "5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77",
            "title": "Launch plan: three decisions",
            "session_id": "2c0f7a10-6f1e-4b0a-9a53-1f6f2d8d9a01",
            "session_title": "Launch planning",
            "url": "https://pai.example.invalid/apps/reports/5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77",
            "answers": {"d1": "Option B"},
            "created_at": "2026-11-26T18:30:00+00:00",
            "updated_at": "2026-11-26T18:45:00+00:00"
          }
        }
        """#

    /// What `GET .../page` serves.
    public static let dynamicReportPage = #"""
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Launch plan: three decisions</title>
        <style>
          body { font: 16px -apple-system, sans-serif; margin: 16px; color: #1c2430; }
          h1 { font-size: 22px; } .opt { display: block; margin: 8px 0; padding: 10px; border: 1px solid #c7d0dc; border-radius: 8px; }
          .opt.on { border-color: #2f6fdd; background: #eaf1fd; }
          button { font: inherit; padding: 10px 14px; border-radius: 8px; border: 0; background: #2f6fdd; color: #fff; }
        </style></head>
        <body>
          <h1>Launch plan</h1>
          <p>Which rollout do you want?</p>
          <div id="options"></div>
          <button id="add">Add to message</button>
          <script>
            var answers = {};
            var options = ['Option A', 'Option B', 'Option C'];
            function draw() {
              var box = document.getElementById('options');
              box.innerHTML = '';
              options.forEach(function (name) {
                var el = document.createElement('button');
                el.className = 'opt' + (answers.d1 === name ? ' on' : '');
                el.textContent = name;
                el.onclick = function () {
                  answers.d1 = name;
                  window.parent.postMessage({protocol: 'pai-report', version: 1, type: 'answers', answers: answers}, '*');
                  draw();
                };
                box.appendChild(el);
              });
            }
            window.addEventListener('message', function (e) {
              var m = e.data;
              if (!m || m.protocol !== 'pai-report' || m.type !== 'init') return;
              answers = m.answers || {};
              draw();
            });
            document.getElementById('add').onclick = function () {
              window.parent.postMessage({protocol: 'pai-report', version: 1, type: 'add-to-message',
                text: 'Launch plan: ' + (answers.d1 || 'no choice yet')}, '*');
            };
            draw();
            window.parent.postMessage({protocol: 'pai-report', version: 1, type: 'ready'}, '*');
          </script>
        </body></html>
        """#
}
