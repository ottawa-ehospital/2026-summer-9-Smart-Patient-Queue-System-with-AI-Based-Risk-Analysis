# Testing Strategy and Test Cases

This document summarizes the testing strategy for the CareFlow prototype. The current project is a functional prototype, so testing focuses on verifying the main workflow across the patient app, FastAPI backend, AI agents, database API, and doctor web dashboard.

## Testing Strategy

Our testing approach combines:

- Manual end-to-end workflow testing
- Backend API testing through FastAPI Swagger UI
- Flutter web dashboard testing in Chrome
- Patient app testing through Flutter web and Android emulator
- Database integration checks through the E-hospital table API

The goal is to confirm that the core workflow works correctly from patient check-in to queue management, feedback alert generation, and completed patient status.

## 1. Backend API Testing

The backend was tested using FastAPI Swagger UI and direct frontend interactions.

Main endpoints tested:

```text
POST /patient/check-in
GET /patient/{local_patient_id}/status
POST /patient/{local_patient_id}/feedback
GET /queues
GET /patients
GET /alerts
POST /patient/{local_patient_id}/start
POST /patient/{local_patient_id}/complete
```

Test cases:

```text
Test Case 1: Patient check-in with valid input
Expected result: The patient is analyzed, assigned a CTAS urgency level, saved into healthcare_records, and added to the correct queue.

Test Case 2: Returning patient with an existing patient_id
Expected result: The backend retrieves related patient information and medical history from the database.

Test Case 3: Missing or invalid required fields
Expected result: The backend returns an error message and does not create an invalid visit record.

Test Case 4: Start consultation
Expected result: The patient status changes from Waiting to In Consultation.

Test Case 5: Mark as completed
Expected result: The patient is removed from the active queue and marked as Completed.
```

## 2. Risk Analysis Agent Testing

The Risk Analysis Agent was tested with different symptom descriptions to check whether it could generate reasonable CTAS levels, risk scores, summaries, reasoning, and recommended actions.

Example test cases:

```text
Test Case 1: Severe chest pain with shortness of breath
Expected result: High urgency CTAS level, high risk score, and Emergency Queue placement.

Test Case 2: Sore throat and mild cough
Expected result: Lower urgency CTAS level, lower risk score, and Non-Urgent Queue placement.

Test Case 3: Fever with abdominal pain and vomiting
Expected result: Medium urgency level and appropriate queue placement based on the generated CTAS level.
```

The Risk Analysis Agent uses both LLM analysis and CTAS-inspired rule logic. The LLM handles free-text symptom interpretation, while the rule logic provides a safety layer for obvious high-risk cases.

## 3. Queue Prioritization Agent Testing

The Queue Prioritization Agent was tested to confirm that patients are sorted by urgency and check-in time.

Test cases:

```text
Test Case 1: CTAS Level 1 patient enters the queue
Expected result: The patient appears before lower urgency patients.

Test Case 2: Multiple patients have the same CTAS level
Expected result: Patients are sorted by check-in time.

Test Case 3: Patient is marked as completed
Expected result: The patient is removed from the active queue and no longer appears as Waiting.
```

The queue logic follows:

```text
CTAS Level 1 -> highest priority
CTAS Level 5 -> lowest priority
Same CTAS level -> earlier check-in time first
```

## 4. Feedback Alert Agent Testing

The Feedback Alert Agent was tested using patient feedback and condition updates.

Example test cases:

```text
Test Case 1: "My chest pain is getting worse and I feel short of breath."
Expected result: Alert required.

Test Case 2: "I feel better now."
Expected result: No urgent alert required.

Test Case 3: "I cannot speak clearly and my arm feels weak."
Expected result: High priority alert required.
```

The Feedback Alert Agent uses:

- LLM-based feedback analysis
- Rule-based keyword fallback
- Alert severity and recommended staff action

The keyword safety layer checks for red-flag terms such as chest pain, shortness of breath, cannot breathe, trouble speaking, fainting, severe pain, weakness, numbness, and similar deterioration signals.

## 5. Database Integration Testing

Database testing focused on checking whether records are saved and linked correctly.

Main database relationships:

```text
patients_registration.patient_id -> healthcare_records.patient_id
medical_history.patient_id -> patients_registration.patient_id
healthcare_records.record_id -> patient_feedback.record_id
```

Test cases:

```text
Test Case 1: New patient check-in
Expected result: A patient registration record is created or reused, and a healthcare_records row is created for the visit.

Test Case 2: Feedback submission
Expected result: A patient_feedback row is created and linked to the correct healthcare_records row through record_id.

Test Case 3: Returning patient
Expected result: Previous patient information and medical history can be retrieved using patient_id.
```

The database design separates patient-level information and visit-level information:

```text
patient_id = identifies the patient
record_id = identifies a specific visit/check-in
feedback_id = identifies a specific feedback entry
```

## 6. Frontend Workflow Testing

The patient app and doctor web dashboard were tested manually.

Patient app test cases:

```text
Submit patient check-in information.
Review information before final confirmation.
View current queue status.
Submit rating, feedback, and condition update.
See updated status after clinician action.
```

Doctor web dashboard test cases:

```text
View priority queues.
Start consultation.
Mark patient as completed.
View urgency distribution.
View feedback alerts.
Dismiss alert cards.
Search completed patient history.
```

## 7. Current Limitations

Current testing is mainly prototype-level and workflow-based. Future testing should include:

```text
Unit tests for backend queue logic.
Mocked LLM response tests.
Mocked database API tests.
Flutter widget tests for the patient app.
Flutter widget tests for the doctor dashboard.
End-to-end tests across app, backend, database, and dashboard.
```

## Summary

The current testing confirms that the main CareFlow workflow is functional:

```text
Patient check-in
-> Risk Analysis Agent
-> Queue Prioritization Agent
-> Database storage
-> Doctor dashboard update
-> Patient status update
-> Feedback Alert Agent
-> Completed patient workflow
```

This level of testing is suitable for the current prototype stage, while more automated tests should be added in future development.
