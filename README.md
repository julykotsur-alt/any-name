# any-name-ai-api-testing

API regression tests for the public [Swagger Petstore v3](https://petstore3.swagger.io/)
(`https://petstore3.swagger.io/api/v3`, OpenAPI spec:
[openapi.json](https://petstore3.swagger.io/api/v3/openapi.json)).

## What it checks

`collections/petstore-collection.json` is a Postman Collection v2.1 that runs the full pet lifecycle:

| # | Request | Endpoint | Expected status (per OpenAPI) |
|---|---------|----------|-------------------------------|
| 1 | Create pet | `POST /pet` | 200 Successful operation |
| 2 | Get created pet | `GET /pet/{petId}` | 200 successful operation |
| 3 | Update pet | `PUT /pet` | 200 Successful operation |
| 4 | Get updated pet | `GET /pet/{petId}` | 200 successful operation |
| 5 | Delete pet | `DELETE /pet/{petId}` | 200 Pet deleted |
| 6 | Verify deletion | `GET /pet/{petId}` | 404 Pet not found |

Every request checks:

- **Status code** matches the OpenAPI documentation.
- **Response schema**: JSON responses are validated against the `Pet` schema from the spec
  (required fields, types, `status` enum).
- **Data consistency**: the response matches exactly what was sent or stored. The update must
  keep the id and change the name and status, and the update must persist.

Test data is generated on each run: the pet `id` (`Date.now() * 1000` plus 3 random digits),
the name, category, tags, photo URL and status. Nothing is hard-coded, so runs do not collide.
`baseUrl` is a collection variable.

**Cleanup:** the collection deletes the pet it created. If the pet still exists at the
"Verify deletion" step, the collection deletes it again and then clears its run variables.

## Requirements

- [Node.js](https://nodejs.org/) 18+
- [Newman](https://www.npmjs.com/package/newman): `npm install -g newman`

## Run

```bash
newman run collections/petstore-collection.json
```

With a JSON results file and an HTML report (needs `npm install -g newman-reporter-htmlextra@1`):

```bash
newman run collections/petstore-collection.json \
  -r cli,json,htmlextra \
  --reporter-json-export results/newman-report.json \
  --reporter-htmlextra-export reports/index.html
```

To test another server (for example a local Petstore), override the base URL:

```bash
newman run collections/petstore-collection.json --env-var baseUrl=http://localhost:8080/api/v3
```

You can also import the collection into the Postman app and run it with the Collection Runner.

## CI: GitHub Actions

Workflow `.github/workflows/newman.yml` — **Any Name API regression (Newman)**.

- **Triggers:**

  | Trigger | Jira gate | Regression |
  |---|---|---|
  | push to `main` changing `collections/**`, `.github/scripts/**` or the workflow | no | always |
  | manual run (Actions → *Any Name API regression (Newman)* → *Run workflow*) | no | always |
  | manual run with **`jira_gate`** ticked | yes | only if tickets are found |
  | **schedule**: every Monday at 07:00 UTC (`0 7 * * 1`) | yes | only if tickets are found |

- **Jira gate** (`jira-gate` job, script `.github/scripts/jira-gate.sh`) runs before Newman:
  1. Fails if the `JIRA_EMAIL` or `JIRA_API_TOKEN` secret is missing, so a scheduled run never
     skips silently.
  2. Checks the login with `GET /rest/api/3/myself` and fails unless it returns a real, active user
     account matching `JIRA_EMAIL`. This is needed because Jira Cloud answers searches anonymously
     (HTTP 200, 0 tickets).
  3. Searches `labels = "api-regression" AND status = "Ready for QA"` with
     `POST /rest/api/3/search/jql` on `https://julykotsur.atlassian.net`.
  4. Writes the tickets found, with links, to the run summary. With 0 tickets, Newman and Pages are
     skipped and the run stays green.
- **Jira update** (`jira-update` job, script `.github/scripts/jira-transition.sh`) runs after Newman,
  only for gated runs (schedule or `jira_gate`) where Newman actually ran. For every ticket the
  gate found:
  - **PASSED** (Newman JSON report: assertions ran, 0 failed requests, test scripts, assertions or
    run errors): moves the ticket **Ready for QA → Done**, but only if it is still in Ready for QA.
    The transition is found by target status name, not by a fixed id.
  - **FAILED**: does not change the status.
  - Either way, it adds a comment with the result, the requests / test-scripts / assertions table
    (executed and failed), and links to the run and, on `main`, the HTML report.
  - It lists what it did per ticket in the run summary, and fails if a transition or comment fails.

  To change the statuses, edit `JIRA_EXPECTED_STATUS` / `JIRA_TARGET_STATUS` in the workflow.
- **Secrets** (Settings → Secrets and variables → Actions):
  - `JIRA_EMAIL`: email of the Atlassian account that owns the API token
  - `JIRA_API_TOKEN`: an API token without scopes, created at
    <https://id.atlassian.com/manage-profile/security/api-tokens>

  ```bash
  gh secret set JIRA_EMAIL --repo julykotsur-alt/any-name
  ```

  ```bash
  gh secret set JIRA_API_TOKEN --repo julykotsur-alt/any-name
  ```

  `gh` prompts for the value, so it does not end up in shell history.

  To test the gate by hand: Actions → *Run workflow* → tick **jira_gate**, or run
  `gh workflow run newman.yml -f jira_gate=true`.

  GitHub pauses scheduled workflows in public repositories after 60 days without repository
  activity; re-enable the workflow in the Actions tab if that happens.
- **Runs:** Node 20, `newman@6` with the `cli`, `json` and `htmlextra` reporters
  (`newman-reporter-htmlextra@1`).
- **Artifacts** (kept 14 days, uploaded even when assertions fail):
  - `newman-report`: JSON report (`results/newman-report.json`)
  - `newman-html-report`: HTML report (`reports/index.html`)
- **GitHub Pages:** on `main`, the separate `publish-report` job publishes the latest HTML report to
  <https://julykotsur-alt.github.io/any-name/> with `actions/deploy-pages`. It runs only when Newman
  actually ran, including when assertions fail, so failures can be inspected. It does not run when
  Newman was skipped by the Jira gate or never started. Manual runs on other branches only upload
  artifacts.
  Pages must use the **GitHub Actions** source (Settings → Pages → Build and deployment).

The job fails when any assertion fails. The HTML report is still published.

> The published report is public and includes request and response bodies. This collection only
> talks to the public Petstore with generated data; do not add secrets to it.

## Layout

```
.github/workflows/newman.yml   CI workflow (Jira gate, Newman run, artifacts, GitHub Pages)
.github/scripts/jira-lib.sh    shared Jira helpers (login check, API calls)
.github/scripts/jira-gate.sh   Jira gate: login check and ticket search
.github/scripts/jira-transition.sh  Jira update: comment and move passed tickets to Done
collections/                   Postman collection
results/                       JSON run results (git-ignored, folder kept with .gitkeep)
reports/                       HTML reports (git-ignored, folder kept with .gitkeep)
```
