# Flutter Frontend

This folder contains the Flutter Web UI for the urgent care queue dashboard.

The Flutter app is frontend only. It calls the FastAPI backend in `backend.py`.

## Run Backend First

```powershell
cd "D:\Urgent Care Queue Dashboard Project"
$env:DEEPSEEK_API_KEY="your_deepseek_key"
py -3 -m uvicorn backend:app --host 0.0.0.0 --port 8001 --reload
```

## Run Flutter Web

```powershell
cd "D:\Urgent Care Queue Dashboard Project\flutter_frontend"
flutter pub get
flutter run -d chrome
```

The default backend API URL in the UI is:

```text
http://127.0.0.1:8001
```

## Implemented UI Functions

- Patient check-in form
- Risk Analysis and Join Queue button
- Dashboard summary cards
- Emergency / Normal / Non-Urgent queues
- Notify Patient, Start Consultation, and Mark as Completed actions
- Feedback Chatbot dialog
- Feedback Alert Agent display
- Urgency distribution panel
- Completed / discharged history
