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

With a JSON results file and an HTML report (needs `npm install -g newman-reporter-htmlextra`):

```bash
newman run collections/petstore-collection.json \
  -r cli,json,htmlextra \
  --reporter-json-export results/petstore-results.json \
  --reporter-htmlextra-export reports/petstore-report.html
```

To test another server (for example a local Petstore), override the base URL:

```bash
newman run collections/petstore-collection.json --env-var baseUrl=http://localhost:8080/api/v3
```

You can also import the collection into the Postman app and run it with the Collection Runner.

## Layout

```
collections/   Postman collection
results/       raw run results (git-ignored, folder kept with .gitkeep)
reports/       generated reports (git-ignored, folder kept with .gitkeep)
```
