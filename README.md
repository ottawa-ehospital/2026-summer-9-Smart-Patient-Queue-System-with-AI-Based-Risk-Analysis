# CareFlow: AI-Powered Urgent Care Queue System

CareFlow is a prototype smart scheduling and queue management system for urgent care, walk-in clinics, and emergency department style workflows. It includes:

- A FastAPI backend
- A Flutter doctor web dashboard
- A Flutter patient app
- E-hospital database API integration
- AI-assisted risk analysis, queue prioritization, and feedback alerts

This project is for clinical decision support and workflow demonstration only. It does not replace doctors, diagnosis, treatment, or professional clinical judgment.

## 1. Project Overview

Walk-in clinics and emergency departments often face long waiting times and unpredictable queues. A first-come, first-served workflow may not reflect patient urgency. CareFlow addresses this by collecting patient check-in information, analyzing symptom urgency, placing patients into priority queues, and monitoring patient feedback for possible deterioration.

The system has two frontend platforms:

- `patient_app/`: patient-facing Flutter app
- `flutter_frontend/`: doctor/staff Flutter web dashboard

Both frontends communicate with:

- `backend.py`: FastAPI backend that connects AI agents, queue logic, and database API

## 2. Main Features

- Patient check-in with patient ID, name, age, gender, symptoms, and optional medical history
- Risk Analysis Agent for CTAS level, risk score, clinical summary, reasoning, and recommended action
- CTAS-inspired rule engine as a safety fallback when LLM output fails or underestimates urgency
- Queue Prioritization Agent with Emergency, Normal, and Non-Urgent queues
- Patient app queue status page with queue position, patients ahead, and estimated wait
- Doctor dashboard with live queues, patient summaries, start consultation, and mark as completed actions
- Feedback Alert Agent for patient feedback and condition updates
- Rule-based keyword fallback for red-flag feedback such as chest pain, breathing difficulty, weakness, or trouble speaking
- Database-backed visit and feedback records using `patient_id` and `record_id`
- Testing strategy and structured test cases under `docs/`

## 3. Project Structure

```text
backend.py                         FastAPI backend, AI agents, queue logic, database API integration
backend_requirements.txt           Python dependencies for backend
api.md                             E-hospital database API notes
README.md                          Main project documentation

flutter_frontend/                  Flutter doctor/staff web dashboard
  lib/main.dart                    Main dashboard UI and backend API calls
  pubspec.yaml                     Flutter dependencies

patient_app/                       Flutter patient-facing app
  lib/main.dart                    Patient check-in, status, info, and feedback UI
  pubspec.yaml                     Flutter dependencies

docs/
  careflow-workflow.svg            Overall system workflow diagram
  database-relationship.svg        Database relationship diagram
  testing-strategy.md              Testing strategy and test case explanation
  test-cases.json                  Structured test cases with expected and simulated results

Feedback_Data/                     Local fallback data folder for prototype use
```

## 4. System Architecture

CareFlow uses a frontend-backend-database architecture:

```text
Patient App
    -> FastAPI Backend
        -> Risk Analysis Agent
        -> Queue Prioritization Agent
        -> Feedback Alert Agent
        -> E-hospital Database API
    -> Doctor Web Dashboard
```

The patient app and doctor dashboard do not directly access the database or LLM. They call the FastAPI backend through REST API endpoints. The backend manages AI analysis, queue state, database persistence, and status synchronization.

## 5. Backend

Main backend file:

```text
backend.py
```

The backend is responsible for:

- Receiving patient check-in data
- Looking up or creating patient registration records
- Reading previous medical history and visit context
- Running the Risk Analysis Agent
- Running the CTAS rule engine safety check
- Saving visit data into `healthcare_records`
- Building Emergency, Normal, and Non-Urgent queues
- Updating patient status when clinicians start or complete consultation
- Saving feedback into `patient_feedback`
- Running the Feedback Alert Agent
- Returning alerts to the doctor dashboard

### Important Backend Endpoints

```text
GET  /health
GET  /docs

POST /patient/check-in
GET  /patient/{local_patient_id}/status
POST /patient/{local_patient_id}/feedback

GET  /queues
GET  /patients
GET  /alerts

POST /patient/{local_patient_id}/start
POST /patient/{local_patient_id}/complete
```

## 6. AI Agent Design

### 6.1 Risk Analysis Agent

Input:

- Patient ID
- Name, age, gender
- Symptom description
- Optional medical history
- Previous visit and feedback context when available

Output:

- CTAS urgency level
- Risk score
- Clinical summary
- Reasoning
- Recommended staff action
- Queue name

The Risk Analysis Agent uses DeepSeek for free-text symptom interpretation. A CTAS-inspired rule engine also runs as a safety layer.

### 6.2 CTAS Rule Engine

The CTAS rule engine provides deterministic if-then style safety rules. It is used when:

- The LLM API fails
- The LLM returns invalid JSON
- The LLM returns an unsupported CTAS level
- The LLM output appears less urgent than a matched safety rule

Examples of rule checks:

- Chest pain with shortness of breath or radiation
- Stroke-like symptoms such as slurred speech or one-sided weakness
- Severe breathing difficulty
- Low oxygen saturation
- Unconsciousness or unresponsiveness
- Seizure or overdose
- Anaphylaxis signs such as throat or tongue swelling
- Severe bleeding or shock
- Severe pain score
- Pregnancy with bleeding or severe abdominal pain

If the rule engine detects a higher-risk pattern, the system can upgrade the CTAS level.

### 6.3 Queue Prioritization Agent

The queue logic is:

```text
CTAS Level 1 -> highest priority
CTAS Level 5 -> lowest priority
Same CTAS level -> higher risk score first
Same CTAS and risk score -> earlier check-in time first
```

Operational queues:

```text
CTAS 1-2 -> Emergency Queue
CTAS 3   -> Normal Queue
CTAS 4-5 -> Non-Urgent Queue
```

### 6.4 Feedback Alert Agent

The Feedback Alert Agent analyzes patient feedback and condition updates after check-in.

Input:

- Patient ID
- Current CTAS level
- Risk score
- Rating
- Feedback message
- Condition update

Output:

- Alert required or not
- Alert severity
- Alert reason
- Recommended staff action
- Patient-facing message

The Feedback Alert Agent uses both:

- LLM-based analysis
- Keyword/rule-based safety fallback

Example red-flag terms include chest pain, shortness of breath, cannot breathe, trouble speaking, weakness, numbness, fainting, seizure, severe pain, and suicidal thoughts.

## 7. Database Design

CareFlow uses the E-hospital database API.

Main tables:

```text
patients_registration
medical_history
healthcare_records
patient_feedback
```

### Table Roles

`patients_registration`

- Stores patient-level registration information
- Uses `patient_id`
- Includes name, date of birth / age, gender, and contact information

`medical_history`

- Stores patient-level medical history notes
- Linked by `patient_id`

`healthcare_records`

- Stores each check-in / visit record
- Contains both `record_id` and `patient_id`
- Includes symptoms, CTAS urgency level, risk score, queue name, status, clinical summary, recommended action, and timestamps

`patient_feedback`

- Stores feedback and condition updates
- Linked to one specific visit by `record_id`
- Includes rating, feedback message, condition update, alert flag, alert reason, and created time

### Relationship Summary

```text
patient_id = identifies the patient
record_id  = identifies one specific visit
feedback_id = identifies one feedback entry
```

Relationship:

```text
one patient_id -> many record_id
one record_id  -> many feedback_id
```

This design allows the system to reuse historical data when the same patient returns for a future visit.

## 8. Patient App

Folder:

```text
patient_app/
```

The patient app is built with Flutter. It is designed for patients to use during arrival and waiting.

Implemented functions:

- Patient check-in
- Patient ID input for returning patients
- Name, age, gender, symptoms, and optional medical history input
- Review page before final submission
- Current queue status
- Patients ahead
- Estimated wait range
- Submitted information page
- Feedback rating
- Condition update submission

The patient app calls the backend through REST API endpoints. For Android emulator testing, it uses:

```text
http://10.0.2.2:8001
```

For Chrome/web testing, use:

```text
http://127.0.0.1:8001
```

## 9. Doctor Web Dashboard

Folder:

```text
flutter_frontend/
```

The doctor dashboard is built with Flutter Web. It is designed for clinicians or clinic staff.

Implemented functions:

- Dashboard overview cards
- Total patients
- Waiting patients
- Patients in consultation
- Completed patients
- Emergency / Normal / Non-Urgent queues
- CTAS urgency level badges
- Risk score display
- Clinical summary
- Clinical decision support report
- Start Consultation action
- Mark as Completed action
- Feedback alerts
- Dismissible alert cards
- Urgency distribution panel
- Completed patient history with search

The doctor web dashboard calls:

```text
http://127.0.0.1:8001
```

by default.

## 10. Local Setup

### 10.1 Install Backend Dependencies

```powershell
cd "D:\Urgent Care Queue Dashboard Project"
py -3 -m pip install -r backend_requirements.txt
```

### 10.2 Set LLM API Key

Current implementation uses DeepSeek:

```powershell
$env:DEEPSEEK_API_KEY="your_deepseek_api_key"
```

API keys should be stored as environment variables. Do not hard-code or commit API keys.

### 10.3 Run Backend

```powershell
cd "D:\Urgent Care Queue Dashboard Project"
py -3 -m uvicorn backend:app --host 0.0.0.0 --port 8001 --reload
```

Backend health check:

```text
http://127.0.0.1:8001/health
```

Swagger API docs:

```text
http://127.0.0.1:8001/docs
```

## 11. Run Doctor Web Dashboard

Open a second terminal:

```powershell
cd "D:\Urgent Care Queue Dashboard Project\flutter_frontend"
flutter pub get
flutter run -d chrome
```

If Flutter is not in PATH, add it first:

```powershell
$env:Path += ";D:\Download\flutter_windows_3.44.4-stable\flutter\bin"
```

## 12. Run Patient App

### Chrome Testing

```powershell
cd "D:\Urgent Care Queue Dashboard Project\patient_app"
flutter pub get
flutter run -d chrome --dart-define=PATIENT_API_BASE=http://127.0.0.1:8001
```

### Android Emulator Testing

Start the backend first, then run:

```powershell
cd "D:\Urgent Care Queue Dashboard Project\patient_app"
flutter pub get
flutter run -d emulator-5554
```

Check available devices:

```powershell
flutter devices
```

If the emulator ID is different, replace `emulator-5554` with the displayed device ID.

## 13. Testing

Testing documents are stored in:

```text
docs/testing-strategy.md
docs/test-cases.json
```

Testing coverage includes:

- Backend API testing
- Patient check-in
- Risk Analysis Agent output
- Queue prioritization
- Doctor dashboard actions
- Patient app status updates
- Feedback Alert Agent behavior
- Database linkage through `patient_id` and `record_id`

Prototype-level testing result:

```text
Total test cases: 12
Passed: 12
Failed: 0
Pass rate: 100%
```

These are manual and simulated prototype tests, not clinical validation.

## 14. Important Notes

- This project is a prototype.
- AI output is decision support only.
- Clinicians must make the final clinical decision.
- API keys should be configured through environment variables.
- Local fallback files under `Feedback_Data/` are for prototype use.
- The intended workflow uses the E-hospital database API.
- The LLM provider can be changed from DeepSeek to OpenAI with small backend changes.

## 15. Future Work

- More automated backend unit tests
- Flutter widget tests for both frontends
- End-to-end testing across patient app, backend, database, and doctor dashboard
- Better authentication and role-based access control
- Stronger privacy and security controls
- More advanced wait time prediction
- Deeper EHR / FHIR integration
- Real-world clinical validation

