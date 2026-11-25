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

- **Triggers:** a push to `main` that changes `collections/**` or the workflow file, and a manual
  run (Actions → *Any Name API regression (Newman)* → *Run workflow*).
- **Runs:** Node 20, `newman@6` with the `cli`, `json` and `htmlextra` reporters
  (`newman-reporter-htmlextra@1`).
- **Artifacts** (kept 14 days, uploaded even when assertions fail):
  - `newman-report`: JSON report (`results/newman-report.json`)
  - `newman-html-report`: HTML report (`reports/index.html`)
- **GitHub Pages:** on `main`, the separate `deploy-report` job publishes the latest HTML report to
  <https://julykotsur-alt.github.io/any-name/> with `actions/deploy-pages`. It also publishes the
  report when assertions fail, so failures can be inspected. Manual runs on other branches only
  upload artifacts.
  Pages must use the **GitHub Actions** source (Settings → Pages → Build and deployment).

The job fails when any assertion fails. The HTML report is still published.

> The published report is public and includes request and response bodies. This collection only
> talks to the public Petstore with generated data; do not add secrets to it.

## Layout

```
.github/workflows/newman.yml   CI workflow (Newman run, artifacts, GitHub Pages)
collections/                   Postman collection
results/                       JSON run results (git-ignored, folder kept with .gitkeep)
reports/                       HTML reports (git-ignored, folder kept with .gitkeep)
```
