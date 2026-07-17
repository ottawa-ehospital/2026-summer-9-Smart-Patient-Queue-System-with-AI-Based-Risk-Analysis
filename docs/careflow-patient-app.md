# CareFlow Patient App Guide

## Overview

The CareFlow Patient App is the patient-side Flutter app for the CareFlow queue system.

It allows a patient to submit a check-in request, view their current queue status, review the current submitted information, and send feedback or condition updates.

## Main Tabs

The app has four main tabs:

### Check-in

The Check-in tab is used to submit a new patient check-in request.

After a successful check-in, the app saves the current patient session and moves to the Status tab. The Check-in tab remains available, so another check-in can still be submitted if needed.

### Status

The Status tab shows the current visit or queue status returned by the backend.

This helps the patient understand the current stage of their visit during the demo.

### My info

The My info tab shows the current submitted patient information saved in the local app session.

It is mainly used for review, so the patient can confirm which check-in record is currently active.

### Feedback

The Feedback tab supports condition updates and app feedback.

Condition updates are used when the patient wants to report that their condition has changed. App feedback is used to comment on the app experience.

## Backend Connection

The app connects to the CareFlow backend through the PATIENT_API_BASE Dart define.

For Android emulator testing, use:

    & "D:\Flutter App\flutter\bin\flutter.bat" run -d emulator-5554 --dart-define=PATIENT_API_BASE=http://10.0.2.2:8001

The backend should be running before launching the app.

Example backend command:

    cd "D:\Urgent_Queue\urgent-care-queue-dashboard"
    py -3 -m uvicorn backend:app --host 0.0.0.0 --port 8001

If port 8001 is already in use, the backend may already be running.

## Demo Test Flow

A simple demo flow is:

1. Start the backend.
2. Start the Android emulator.
3. Run the Patient App with the correct PATIENT_API_BASE value.
4. Open the Check-in tab.
5. Submit a patient check-in request.
6. Confirm the app moves to the Status tab.
7. Check the current status.
8. Open My info and confirm the current submitted information is shown.
9. Open Feedback.
10. Submit a condition update or app feedback.
11. Confirm the backend or dashboard can receive the patient-side information.

## Files That Should Not Be Committed

Do not commit generated Flutter or Android build files.

Examples:

- patient_app/build/
- patient_app/.dart_tool/
- patient_app/android/.gradle/
- patient_app/android/local.properties
- APK files
- keystore files
- .env files
- backup folders

Only source files and required project configuration files should be committed.
