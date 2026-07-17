# API Reference

All responses are JSON. Endpoints operate directly on the MySQL tables that Sequelize introspects at runtime.

API URL: https://aetab8pjmb.us-east-1.awsapprunner.com

Example:
To access the patient_feedback table:
https://aetab8pjmb.us-east-1.awsapprunner.com/table/patient_feedback

## `GET /`
Returns a health payload and the list of detected tables.

```http
GET / HTTP/1.1
Host: localhost:8080
```
```json
{
  "message": "MySQL Database service is running",
  "status": "healthy",
  "timestamp": "2025-09-18T15:45:00.000Z",
  "tables": [
    "DEV01.patients_registration",
    "DEV01.doctors_registration"
  ]
}
```

## `GET /tables`
Returns metadata about each detected table, including primary keys and column names.

```http
GET /tables HTTP/1.1
Host: localhost:8080
```
```json
{
  "count": 2,
  "tables": [
    {
      "schema": "DEV01",
      "name": "patients_registration",
      "qualifiedName": "DEV01.patients_registration",
      "modelName": "PatientsRegistration",
      "primaryKeys": ["patient_id"],
      "attributes": ["patient_id", "name", "dob", "gender", "contact_info"]
    }
  ]
}
```

## `POST /sql/select`
Runs a single read-only SQL SELECT query. The query must start with `SELECT` or `WITH`; mutating statements and multiple statements are rejected. Use `replacements` for user-provided values.

```http
POST /sql/select HTTP/1.1
Content-Type: application/json

{
  "sql": "SELECT patient_id, name FROM patients_registration WHERE name LIKE :name LIMIT 20",
  "replacements": {
    "name": "%Jane%"
  }
}
```
```json
{
  "count": 1,
  "data": [
    {
      "patient_id": 1,
      "name": "Jane Doe"
    }
  ]
}
```

## `GET /table/:name`
Returns all rows from the table.

```http
GET /table/patients_registration HTTP/1.1
Host: localhost:8080
```
```json
{
  "table": "DEV01.patients_registration",
  "count": 2,
  "data": [
    { "patient_id": 1, "name": "Jane Doe" },
    { "patient_id": 2, "name": "John Smith" }
  ]
}
```

## `GET /table/:name/:id`
Fetches a single row using the table's primary key (single-column PKs only).

```http
GET /table/patients_registration/1 HTTP/1.1
Host: localhost:8080
```
```json
{
  "patient_id": 1,
  "name": "Jane Doe"
}
```

## `POST /table/:name`
Creates a new row. Payload keys must match column names.

```http
POST /table/patients_registration HTTP/1.1
Content-Type: application/json

{
  "name": "Alice Example",
  "dob": "1990-01-01",
  "gender": "female",
  "contact_info": "alice@example.com"
}
```
```json
{
  "message": "Record created successfully",
  "data": {
    "patient_id": 21,
    "name": "Alice Example",
    "dob": "1990-01-01",
    "gender": "female",
    "contact_info": "alice@example.com"
  }
}
```

## `PUT /table/:name/:id`
Updates an existing row identified by the primary key.

```http
PUT /table/patients_registration/21 HTTP/1.1
Content-Type: application/json

{
  "phone_number": "+1-555-0100"
}
```
```json
{
  "message": "Record updated successfully",
  "data": {
    "patient_id": 21,
    "name": "Alice Example",
    "dob": "1990-01-01",
    "gender": "female",
    "contact_info": "alice@example.com",
    "phone_number": "+1-555-0100"
  }
}
```

## `DELETE /table/:name/:id`
Deletes the row identified by the primary key.

```http
DELETE /table/patients_registration/21 HTTP/1.1
```
```json
{
  "message": "Record deleted successfully"
}
```

### Error responses
- `400` – invalid table name, unsupported primary key, invalid payload, or invalid SQL SELECT query
- `404` – table or row not found
- `500` – internal error while querying the database
