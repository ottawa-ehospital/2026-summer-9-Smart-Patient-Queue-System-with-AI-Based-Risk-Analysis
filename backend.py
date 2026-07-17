"""
FastAPI backend for the Urgent Care Queue Dashboard.

This file is backend-only. It exposes APIs for a Flutter/Web frontend:
- Risk Analysis Agent with DeepSeek
- Queue Prioritization Agent with three operational queues
- Patient feedback persistence through the database API described in api.md
- Patient history retrieval so repeat visits can use previous feedback

Run:
    py -3 -m pip install -r backend_requirements.txt
    $env:DEEPSEEK_API_KEY="your_deepseek_key"
    py -3 -m uvicorn backend:app --host 0.0.0.0 --port 8001 --reload
"""

import http.client
import json
import os
import re
import traceback
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

import requests
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field


DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY")
DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
DATABASE_API_URL = os.getenv("DATABASE_API_URL", "https://aetab8pjmb.us-east-1.awsapprunner.com")
HEALTHCARE_RECORDS_TABLE = os.getenv("HEALTHCARE_RECORDS_TABLE", "healthcare_records")
FEEDBACK_TABLE = os.getenv("FEEDBACK_TABLE", "patient_feedback")
PATIENTS_REGISTRATION_TABLE = os.getenv("PATIENTS_REGISTRATION_TABLE", "patients_registration")
MEDICAL_HISTORY_TABLE = os.getenv("MEDICAL_HISTORY_TABLE", "medical_history")
BACKEND_VERSION = "2026-07-09-timezone-debug"

DATA_DIR = Path(os.getenv("SMART_SCHEDULING_DATA_DIR", Path(__file__).with_name("Feedback_Data")))
PATIENT_FILE = DATA_DIR / "patients.json"
COMPLETED_FILE = DATA_DIR / "completed_patients.json"
LOCAL_FEEDBACK_FILE = DATA_DIR / "feedback_log.json"
ALERT_FILE = DATA_DIR / "feedback_alerts.json"

STATUS_WAITING = "Waiting"
STATUS_CONSULTATION = "In Consultation"
STATUS_COMPLETED = "Completed"
LEGACY_COMPLETED_STATUS = "Completed / Discharged"

QUEUE_EMERGENCY = "Emergency Queue"
QUEUE_NORMAL = "Normal Queue"
QUEUE_NON_URGENT = "Non-Urgent Queue"

CTAS_LEVELS: Dict[int, Dict[str, str]] = {
    1: {"label": "Level 1: Resuscitation / Critical", "short": "Resuscitation / Critical", "color": "#b91c1c"},
    2: {"label": "Level 2: Emergent", "short": "Emergent", "color": "#c2410c"},
    3: {"label": "Level 3: Urgent", "short": "Urgent", "color": "#a16207"},
    4: {"label": "Level 4: Less Urgent", "short": "Less Urgent", "color": "#15803d"},
    5: {"label": "Level 5: Non-Urgent", "short": "Non-Urgent", "color": "#475569"},
}


def ctas_label(level: int) -> str:
    return CTAS_LEVELS[level]["label"]


def queue_name_for_ctas(level: int) -> str:
    """Queue Prioritization Agent action: assign one of three operational queues."""
    if level in (1, 2):
        return QUEUE_EMERGENCY
    if level == 3:
        return QUEUE_NORMAL
    return QUEUE_NON_URGENT


def fallback_risk_score_from_ctas(level: int) -> int:
    return {1: 10, 2: 8, 3: 6, 4: 3, 5: 1}.get(level, 1)


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def now_database_text() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S%z")


@dataclass
class Patient:
    id: int
    patient_id: int
    name: str
    age: int
    symptoms: str
    medical_history: str
    ctas_level: int
    risk_score: int
    queue_name: str
    clinical_summary: str
    reasoning: str
    recommended_action: str
    status: str = STATUS_WAITING
    checked_in_at: str = field(default_factory=now_iso)
    consultation_started_at: Optional[str] = None
    completed_at: Optional[str] = None
    notified_at: Optional[str] = None


class IntakeRequest(BaseModel):
    patient_id: Optional[int] = Field(
        None,
        description="Database patient id if known. If omitted, backend uses a local demo id.",
    )
    name: str = Field(..., min_length=1)
    age: int = Field(..., ge=0, le=125)
    gender: str = Field("Other", description="Male, Female, or Other")
    symptoms: str = Field(..., min_length=1)
    medical_history: str = ""


class FeedbackRequest(BaseModel):
    patient_id: int
    rating: str = Field(..., description="Reasonable, Too high, Too low, or Unsure")
    message: str = Field("", description="Feedback about queue experience or urgency level")
    condition_update: str = Field("", description="Optional patient condition update for alert analysis")
    ctas_level: Optional[int] = None
    risk_score: Optional[int] = None


class FeedbackAlert(BaseModel):
    alert_required: bool
    severity: str = "none"
    alert_reason: str = ""
    recommended_staff_action: str = ""
    patient_message: str = ""
    feedback_type: str = "triage_review"
    agent_source: str = "keyword_safety_fallback"


app = FastAPI(title="Urgent Care Queue Dashboard Backend")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def load_json_list(path: Path) -> List[dict]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
    except (OSError, json.JSONDecodeError):
        return []
    return data if isinstance(data, list) else []


def save_json_list(path: Path, rows: List[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(rows, file, ensure_ascii=False, indent=2)


def patient_from_dict(row: dict) -> Patient:
    fields = Patient.__dataclass_fields__.keys()
    payload = {key: row[key] for key in fields if key in row}
    if payload.get("status") == LEGACY_COMPLETED_STATUS:
        payload["status"] = STATUS_COMPLETED
    return Patient(**payload)


def load_patients() -> List[Patient]:
    database_records = load_healthcare_records_from_database()
    if database_records is not None:
        return [patient for patient in database_records if patient.status != STATUS_COMPLETED]
    return [patient_from_dict(row) for row in load_json_list(PATIENT_FILE)]


def save_patients(patients: List[Patient]) -> None:
    save_json_list(PATIENT_FILE, [asdict(patient) for patient in patients])


def try_save_patients(patients: List[Patient]) -> dict:
    try:
        save_patients(patients)
        return {"saved_locally": True}
    except Exception as exc:
        return {"saved_locally": False, "error": str(exc)}


def load_completed_patients() -> List[Patient]:
    database_records = load_healthcare_records_from_database()
    if database_records is not None:
        return [patient for patient in database_records if patient.status == STATUS_COMPLETED]
    return [patient_from_dict(row) for row in load_json_list(COMPLETED_FILE)]


def save_completed_patients(patients: List[Patient]) -> None:
    save_json_list(COMPLETED_FILE, [asdict(patient) for patient in patients])


def try_save_completed_patients(patients: List[Patient]) -> dict:
    try:
        save_completed_patients(patients)
        return {"saved_locally": True}
    except Exception as exc:
        return {"saved_locally": False, "error": str(exc)}


def next_local_id(patients: List[Patient], completed: List[Patient]) -> int:
    ids = [patient.id for patient in patients + completed]
    return max(ids, default=0) + 1


def parse_dt(value: Optional[str]) -> datetime:
    if not value:
        return datetime.now()
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return datetime.now()
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone().replace(tzinfo=None)
    return parsed


def waiting_minutes(patient: Patient) -> int:
    start = parse_dt(patient.checked_in_at)
    end = parse_dt(patient.consultation_started_at) if patient.consultation_started_at else parse_dt(None)
    return max(0, int((end - start).total_seconds() // 60))


def serialize_patient(patient: Patient) -> dict:
    row = asdict(patient)
    row["urgency_label"] = ctas_label(patient.ctas_level)
    row["waiting_minutes"] = waiting_minutes(patient)
    return row


def database_url(path: str) -> str:
    return f"{DATABASE_API_URL.rstrip('/')}/{path.lstrip('/')}"


def db_get_table(table_name: str) -> List[dict]:
    response = requests.get(database_url(f"/table/{table_name}"), timeout=12)
    response.raise_for_status()
    data = response.json()
    rows = data.get("data", [])
    return rows if isinstance(rows, list) else []


def db_create_row(table_name: str, payload: dict) -> dict:
    response = requests.post(database_url(f"/table/{table_name}"), json=payload, timeout=12)
    try:
        response.raise_for_status()
    except requests.HTTPError as exc:
        raise RuntimeError(f"{response.status_code} {response.text}") from exc
    return response.json()


def db_update_row(table_name: str, row_id: int, payload: dict) -> dict:
    response = requests.put(database_url(f"/table/{table_name}/{row_id}"), json=payload, timeout=12)
    try:
        response.raise_for_status()
    except requests.HTTPError as exc:
        raise RuntimeError(f"{response.status_code} {response.text}") from exc
    return response.json()


def age_from_dob(dob: Optional[str]) -> int:
    if not dob:
        return 0
    try:
        birth_date = datetime.fromisoformat(str(dob).split("T")[0])
    except ValueError:
        return 0
    today = datetime.now()
    return max(0, today.year - birth_date.year - ((today.month, today.day) < (birth_date.month, birth_date.day)))


def approximate_dob_from_age(age: int) -> str:
    year = datetime.now().year - age
    return f"{year}-01-01"


def load_patient_registration_map() -> Dict[int, dict]:
    try:
        rows = db_get_table(PATIENTS_REGISTRATION_TABLE)
    except Exception:
        return {}
    profiles: Dict[int, dict] = {}
    for row in rows:
        try:
            profiles[int(row.get("patient_id"))] = row
        except (TypeError, ValueError):
            continue
    return profiles


def load_medical_history_notes_map() -> Dict[int, str]:
    try:
        rows = db_get_table(MEDICAL_HISTORY_TABLE)
    except Exception:
        return {}

    latest_rows: Dict[int, dict] = {}
    for row in rows:
        try:
            patient_id = int(row.get("patient_id"))
        except (TypeError, ValueError):
            continue
        notes = str(row.get("notes") or "").strip()
        if not notes:
            continue
        current = latest_rows.get(patient_id)
        current_time = parse_dt(current.get("last_updated") or current.get("diagnosis_date")) if current else None
        row_time = parse_dt(row.get("last_updated") or row.get("diagnosis_date"))
        if current is None or row_time >= current_time:
            latest_rows[patient_id] = row

    return {
        patient_id: str(row.get("notes") or "").strip()
        for patient_id, row in latest_rows.items()
    }


def ensure_patient_registration(patient_id: int, name: str, age: int, gender: str) -> dict:
    profiles = load_patient_registration_map()
    if patient_id in profiles:
        return {"registered": True, "created": False, "patient": profiles[patient_id]}

    normalized_gender = gender if gender in {"Male", "Female", "Other"} else "Other"
    payload = {
        "patient_id": patient_id,
        "name": name.strip(),
        "dob": approximate_dob_from_age(age),
        "gender": normalized_gender,
        "contact_info": "Not provided",
    }
    try:
        result = db_create_row(PATIENTS_REGISTRATION_TABLE, payload)
        return {"registered": True, "created": True, "database_response": result}
    except Exception as exc:
        return {"registered": False, "created": False, "error": str(exc), "attempted_payload": payload}


SUMMARY_REASONING_SEPARATOR = "\n\nReasoning:\n"


def pack_summary_with_reasoning(summary: str, reasoning: str) -> str:
    summary = summary.strip()
    reasoning = reasoning.strip()
    if not reasoning:
        return summary
    return f"{summary}{SUMMARY_REASONING_SEPARATOR}{reasoning}"


def unpack_summary_with_reasoning(value: str) -> tuple[str, str]:
    if SUMMARY_REASONING_SEPARATOR not in value:
        return value.strip(), ""
    summary, reasoning = value.split(SUMMARY_REASONING_SEPARATOR, 1)
    return summary.strip(), reasoning.strip()


def patient_from_healthcare_record(
    row: dict,
    profile: Optional[dict] = None,
    medical_history_note: str = "",
) -> Patient:
    ctas_level = int(row.get("ctas_urgency_level") or row.get("ctas_level") or 5)
    risk_score = int(row.get("risk_score") or fallback_risk_score_from_ctas(ctas_level))
    record_id = int(row.get("record_id") or row.get("id") or row.get("patient_id") or 0)
    patient_id = int(row.get("patient_id") or record_id)
    profile = profile or {}
    status = str(row.get("status") or STATUS_WAITING)
    if status == LEGACY_COMPLETED_STATUS:
        status = STATUS_COMPLETED
    clinical_summary, stored_reasoning = unpack_summary_with_reasoning(str(row.get("clinical_summary") or ""))
    recommended_action = str(row.get("recommended_action") or "")
    default_reasoning = (
        f"Clinical decision support report: CTAS Level {ctas_level} with risk score {risk_score}/10. "
        f"Queue assignment: {row.get('queue_name') or queue_name_for_ctas(ctas_level)}. "
        f"Clinical summary: {clinical_summary or 'No clinical summary available.'} "
        f"Recommended staff action: {recommended_action or 'No recommended action available.'} "
        "This is decision support only and should be reviewed by clinical staff."
    )
    return Patient(
        id=record_id,
        patient_id=patient_id,
        name=str(profile.get("name") or row.get("name") or f"Patient {patient_id}"),
        age=age_from_dob(profile.get("dob")) or int(row.get("age") or 0),
        symptoms=str(row.get("symptoms") or ""),
        medical_history=str(row.get("medical_history") or medical_history_note or ""),
        ctas_level=ctas_level,
        risk_score=risk_score,
        queue_name=str(row.get("queue_name") or queue_name_for_ctas(ctas_level)),
        clinical_summary=clinical_summary,
        reasoning=str(row.get("reasoning") or stored_reasoning or default_reasoning),
        recommended_action=recommended_action,
        status=status,
        checked_in_at=str(row.get("check_in_time") or row.get("checked_in_at") or now_iso()),
        consultation_started_at=row.get("consultation_started_at"),
        completed_at=row.get("completed_at"),
    )


def patient_to_healthcare_record(patient: Patient) -> dict:
    return {
        "patient_id": patient.patient_id,
        "symptoms": patient.symptoms,
        "ctas_urgency_level": patient.ctas_level,
        "risk_score": patient.risk_score,
        "queue_name": patient.queue_name,
        "status": patient.status,
        "clinical_summary": pack_summary_with_reasoning(patient.clinical_summary, patient.reasoning),
        "recommended_action": patient.recommended_action,
        "check_in_time": patient.checked_in_at,
        "consultation_started_at": patient.consultation_started_at,
        "completed_at": patient.completed_at,
    }


def load_healthcare_records_from_database() -> Optional[List[Patient]]:
    try:
        rows = db_get_table(HEALTHCARE_RECORDS_TABLE)
        profiles = load_patient_registration_map()
        medical_history_notes = load_medical_history_notes_map()
        return [
            patient_from_healthcare_record(
                row,
                profiles.get(int(row.get("patient_id") or 0)),
                medical_history_notes.get(int(row.get("patient_id") or 0), ""),
            )
            for row in rows
        ]
    except Exception:
        return None


def find_record_id_in_response(value) -> Optional[int]:
    if isinstance(value, dict):
        for key in ("record_id", "id"):
            if value.get(key) is not None:
                try:
                    return int(value[key])
                except (TypeError, ValueError):
                    pass
        for child in value.values():
            found = find_record_id_in_response(child)
            if found is not None:
                return found
    if isinstance(value, list):
        for item in value:
            found = find_record_id_in_response(item)
            if found is not None:
                return found
    return None


def refresh_record_id_from_database(patient: Patient) -> Optional[int]:
    try:
        rows = db_get_table(HEALTHCARE_RECORDS_TABLE)
    except Exception:
        return None

    candidates = []
    for row in rows:
        symptoms_match = str(row.get("symptoms") or "") == patient.symptoms
        patient_match = str(row.get("patient_id") or "") == str(patient.patient_id)
        time_match = str(row.get("check_in_time") or row.get("checked_in_at") or "").startswith(
            patient.checked_in_at[:19]
        )
        if symptoms_match and (patient_match or time_match):
            candidates.append(row)

    if not candidates:
        return None

    candidates.sort(
        key=lambda row: parse_dt(str(row.get("check_in_time") or row.get("checked_in_at") or "")),
        reverse=True,
    )
    try:
        return int(candidates[0]["record_id"])
    except (KeyError, TypeError, ValueError):
        return None


def create_healthcare_record(patient: Patient) -> dict:
    try:
        result = db_create_row(HEALTHCARE_RECORDS_TABLE, patient_to_healthcare_record(patient))
        record_id = find_record_id_in_response(result) or refresh_record_id_from_database(patient)
        if record_id is not None:
            patient.id = record_id
        return {"saved_to_database": True, "record_id": patient.id, "database_response": result}
    except Exception as exc:
        return {"saved_to_database": False, "error": str(exc)}


def save_medical_history_note(patient: Patient) -> dict:
    if not patient.medical_history.strip():
        return {"saved_to_database": False, "skipped": True, "reason": "No medical history provided."}
    now = now_database_text()
    payload = {
        "patient_id": patient.patient_id,
        "diagnosed_by": "Patient self-report",
        "condition": "Patient-reported medical history",
        "status": "Active",
        "severity": "Unspecified",
        "diagnosis_date": now,
        "notes": patient.medical_history,
        "treatment_given": "",
        "followup_required": "false",
        "last_updated": now,
    }
    try:
        result = db_create_row(MEDICAL_HISTORY_TABLE, payload)
        return {"saved_to_database": True, "database_response": result}
    except Exception as exc:
        return {"saved_to_database": False, "error": str(exc)}


def update_healthcare_record(record_id: int, payload: dict) -> dict:
    try:
        result = db_update_row(HEALTHCARE_RECORDS_TABLE, record_id, payload)
        return {"updated_database": True, "database_response": result}
    except Exception as exc:
        return {"updated_database": False, "error": str(exc)}


def current_record_for_patient(patient_id: int) -> Optional[Patient]:
    records = load_healthcare_records_from_database()
    if not records:
        records = load_patients() + load_completed_patients()
    matches = [record for record in records if record.patient_id == patient_id]
    if not matches:
        return None
    matches.sort(key=lambda record: parse_dt(record.checked_in_at), reverse=True)
    return matches[0]


def fetch_patient_history(patient_id: int, limit: int = 5) -> List[dict]:
    """Read previous visit and feedback records from the E-hospital database API."""
    records_sql = {
        "sql": (
            f"SELECT * FROM {HEALTHCARE_RECORDS_TABLE} "
            "WHERE patient_id = :patient_id "
            "ORDER BY check_in_time DESC "
            "LIMIT :limit"
        ),
        "replacements": {"patient_id": patient_id, "limit": limit},
    }
    history_rows: List[dict] = []
    try:
        response = requests.post(database_url("/sql/select"), json=records_sql, timeout=12)
        response.raise_for_status()
        record_rows = response.json().get("data", [])
        record_ids = []
        if isinstance(record_rows, list):
            for row in record_rows:
                row["_history_source"] = "healthcare_record"
                history_rows.append(row)
                if row.get("record_id") is not None:
                    record_ids.append(row["record_id"])
        for record_id in record_ids[:limit]:
            feedback_sql = {
                "sql": (
                    f"SELECT * FROM {FEEDBACK_TABLE} "
                    "WHERE record_id = :record_id "
                    "ORDER BY created_time DESC "
                    "LIMIT :limit"
                ),
                "replacements": {"record_id": record_id, "limit": limit},
            }
            feedback_response = requests.post(database_url("/sql/select"), json=feedback_sql, timeout=12)
            feedback_response.raise_for_status()
            feedback_rows = feedback_response.json().get("data", [])
            if isinstance(feedback_rows, list):
                for row in feedback_rows:
                    row["_history_source"] = "feedback"
                    history_rows.append(row)
        return history_rows
    except Exception:
        # Fallback for deployments where /sql/select is unavailable.
        try:
            feedback_rows = db_get_table(FEEDBACK_TABLE)
            record_rows = db_get_table(HEALTHCARE_RECORDS_TABLE)
            record_ids = set()
            for row in record_rows:
                if str(row.get("patient_id")) == str(patient_id):
                    row["_history_source"] = "healthcare_record"
                    history_rows.append(row)
                    record_ids.add(str(row.get("record_id")))
            for row in feedback_rows:
                if str(row.get("record_id")) in record_ids:
                    row["_history_source"] = "feedback"
                    history_rows.append(row)
            return history_rows[: limit * 2]
        except Exception:
            return []


def save_feedback_to_database(feedback: dict, local_feedback: Optional[dict] = None) -> dict:
    """Write patient feedback to the database API and also keep a local fallback copy."""
    local_rows = load_json_list(LOCAL_FEEDBACK_FILE)
    local_rows.append(local_feedback or feedback)
    save_json_list(LOCAL_FEEDBACK_FILE, local_rows)

    try:
        result = db_create_row(FEEDBACK_TABLE, feedback)
        return {"saved_to_database": True, "database_response": result}
    except Exception as exc:
        return {"saved_to_database": False, "error": str(exc)}


def format_history_for_prompt(history_rows: List[dict]) -> str:
    if not history_rows:
        return "No previous visit or feedback records found."

    lines = []
    for row in history_rows:
        source = row.get("_history_source", "record")
        if source == "healthcare_record":
            date = row.get("check_in_time") or "unknown date"
            detail = (
                f"- Previous visit on {date}: symptoms={row.get('symptoms', '')}; "
                f"CTAS={row.get('ctas_urgency_level', 'unknown')}; "
                f"risk_score={row.get('risk_score', 'unknown')}; "
                f"summary={row.get('clinical_summary', '')}; "
                f"recommended_action={row.get('recommended_action', '')}; "
                f"status={row.get('status', '')}"
            )
        else:
            date = row.get("created_time") or row.get("datetime") or row.get("created_at") or "unknown date"
            feedback = row.get("feedback_message") or row.get("feedback") or row.get("message") or row.get("comment") or ""
            condition = row.get("condition_update") or ""
            rating = row.get("rating") or ""
            alert_required = row.get("alert_required")
            detail = f"- Feedback on {date}: rating={rating}; feedback={feedback}; condition_update={condition}"
            if alert_required is not None:
                detail += (
                    f" | alert_required={alert_required}; "
                    f"alert_severity={row.get('alert_severity', '')}; "
                    f"alert_reason={row.get('alert_reason', '')}"
                )
        lines.append(detail)
    return "\n".join(lines)


def call_deepseek_json(prompt: str, system_message: str) -> dict:
    if not DEEPSEEK_API_KEY:
        raise HTTPException(
            status_code=400,
            detail="DEEPSEEK_API_KEY is missing. Set it before using the Risk Analysis Agent.",
        )

    headers = {
        "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
        "Content-Type": "application/json",
    }
    body = json.dumps(
        {
            "model": DEEPSEEK_MODEL,
            "messages": [
                {"role": "system", "content": system_message},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.1,
        }
    )

    try:
        conn = http.client.HTTPSConnection("api.deepseek.com", timeout=30)
        conn.request("POST", "/chat/completions", body=body, headers=headers)
        response = conn.getresponse()
        raw = response.read().decode("utf-8")
        conn.close()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"DeepSeek API call failed: {exc}") from exc

    if response.status != 200:
        raise HTTPException(status_code=502, detail=f"DeepSeek API returned HTTP {response.status}: {raw}")

    try:
        data = json.loads(raw)
        text = data["choices"][0]["message"]["content"].strip()
        text = text.removeprefix("```json").removeprefix("```").removesuffix("```").strip()
        return json.loads(text)
    except Exception as exc:
        raise HTTPException(status_code=502, detail="DeepSeek response could not be parsed as JSON.") from exc


def keyword_feedback_alert(request: FeedbackRequest) -> FeedbackAlert:
    """Fallback Feedback Alert Agent when the LLM is unavailable."""
    text = f"{request.condition_update} {request.message}".lower()
    high_risk_terms = [
        "worse",
        "worsening",
        "chest pain",
        "shortness of breath",
        "can't breathe",
        "cannot breathe",
        "can't speak",
        "cannot speak",
        "cant speak",
        "unable to speak",
        "trouble speaking",
        "difficulty speaking",
        "need help",
        "need assistance",
        "faint",
        "fainted",
        "passed out",
        "seizure",
        "bleeding",
        "severe pain",
        "stroke",
        "weakness",
        "numbness",
        "confused",
        "suicidal",
        "oxygen",
    ]
    mismatch_terms = ["too low", "undertriaged", "not urgent enough", "waited too long"]
    has_high_risk_term = any(term in text for term in high_risk_terms)
    has_mismatch = request.rating in {"Too low", "Unsure"} or any(term in text for term in mismatch_terms)

    if has_high_risk_term:
        return FeedbackAlert(
            alert_required=True,
            severity="high",
            alert_reason="Feedback contains possible symptom worsening or red-flag language.",
            recommended_staff_action="Ask clinical staff to reassess the patient as soon as possible.",
            patient_message=(
                "Thank you for telling us. Your feedback suggests symptoms may need prompt review, "
                "so staff should reassess the case."
            ),
            feedback_type="symptom_alert",
        )

    if has_mismatch:
        return FeedbackAlert(
            alert_required=True,
            severity="medium",
            alert_reason="Feedback suggests the urgency level may not have matched the patient's condition.",
            recommended_staff_action="Flag this case for staff review and future triage quality improvement.",
            patient_message=(
                "Thank you for the feedback. This case will be flagged for clinical review and system improvement."
            ),
            feedback_type="urgency_mismatch",
        )

    return FeedbackAlert(
        alert_required=False,
        severity="none",
        alert_reason="No immediate clinical warning signs were detected in the feedback.",
        recommended_staff_action="Store feedback for future visit context.",
        patient_message=(
            "Thank you. We are glad the urgency level matched your expectation. "
            "We hope the patient feels better soon."
        ),
        feedback_type="triage_review",
    )


def feedback_alert_agent(request: FeedbackRequest) -> FeedbackAlert:
    """Feedback Alert Agent: analyze feedback and decide whether staff should be warned."""
    fallback = keyword_feedback_alert(request)
    if not DEEPSEEK_API_KEY:
        return fallback

    prompt = f"""
You are a healthcare feedback alert agent for an urgent care triage system.
Analyze the patient/staff feedback after check-in.

Current triage context:
- Patient ID: {request.patient_id}
- CTAS level: {request.ctas_level if request.ctas_level is not None else "not provided"}
- Risk score: {request.risk_score if request.risk_score is not None else "not provided"}
- Rating: {request.rating}
- Queue/urgency feedback: {request.message or "No queue feedback provided."}
- Current patient condition update: {request.condition_update or "No condition update provided."}

Task:
Focus especially on the current patient condition update. Decide whether it contains
signs of symptom worsening, red-flag symptoms, under-triage concern, or urgent need
for staff review. Use the queue feedback only as supporting context.

Trigger an alert when the update suggests acute deterioration or immediate staff review,
including but not limited to: cannot speak, trouble speaking, cannot breathe, shortness
of breath, chest pain, fainting, confusion, severe pain, bleeding, seizure, stroke-like
symptoms, suicidal thoughts, or the patient explicitly asks for urgent help.

Do not require exact keyword matches. Infer risk from the meaning of the patient's words.
When uncertain, be conservative and recommend staff review.

Return JSON only with:
{{
  "alert_required": true or false,
  "severity": "none", "low", "medium", or "high",
  "alert_reason": "short reason",
  "recommended_staff_action": "short action for clinic staff",
  "patient_message": "brief patient-facing reply in English",
  "feedback_type": "triage_review", "urgency_mismatch", "symptom_alert", or "service_experience",
  "agent_source": "deepseek_feedback_alert_agent"
}}

This is decision support only and does not diagnose or treat.
"""
    system_message = "You are a concise clinical safety feedback agent. Return valid JSON only."

    try:
        result = call_deepseek_json(prompt, system_message)
        alert = FeedbackAlert(**result)
    except Exception:
        return fallback

    if fallback.alert_required and not alert.alert_required:
        return fallback
    alert.agent_source = "deepseek_feedback_alert_agent"
    return alert


def save_feedback_alert(alert_record: dict) -> None:
    alerts = load_json_list(ALERT_FILE)
    alerts.append(alert_record)
    save_json_list(ALERT_FILE, alerts)


def feedback_alert_display_key(alert: dict) -> str:
    """Group the database row and local alert file entry from the same feedback event."""
    record_id = str(alert.get("record_id") or "").strip()
    patient_id = str(alert.get("patient_id") or "").strip()
    condition_update = str(alert.get("condition_update") or "").strip().lower()
    feedback = str(alert.get("feedback") or alert.get("feedback_message") or "").strip().lower()
    reason = str(alert.get("alert_reason") or "").strip().lower()
    return "|".join([record_id, patient_id, condition_update, feedback, reason])


def contains_any(text: str, terms: List[str]) -> bool:
    return any(term in text for term in terms)


def extract_max_pain_score(text: str) -> Optional[int]:
    scores = []
    for match in re.finditer(r"(?:pain|severity)[^\d]{0,12}(\d{1,2})\s*(?:/|out of)\s*10", text):
        try:
            scores.append(int(match.group(1)))
        except ValueError:
            continue
    for match in re.finditer(r"(\d{1,2})\s*/\s*10", text):
        try:
            scores.append(int(match.group(1)))
        except ValueError:
            continue
    return max(scores) if scores else None


def extract_low_oxygen(text: str) -> Optional[int]:
    for match in re.finditer(r"(?:oxygen|spo2|o2|saturation)[^\d]{0,16}(\d{2,3})\s*%?", text):
        try:
            value = int(match.group(1))
        except ValueError:
            continue
        if value <= 92:
            return value
    return None


def ctas_rule_engine(request: IntakeRequest, history_rows: List[dict]) -> dict:
    """CTAS-inspired safety rule engine used to validate or replace LLM output.

    The rules are decision-support heuristics derived from common CTAS red-flag
    patterns in the prehospital CTAS guide: airway/breathing/circulation threats,
    acute neurologic deficits, severe pain, anaphylaxis, major bleeding, sepsis
    concern, pregnancy red flags, and low-acuity minor complaints.
    """
    text = f"{request.symptoms} {request.medical_history}".lower()
    pain_score = extract_max_pain_score(text)
    low_oxygen = extract_low_oxygen(text)
    matched_rules: List[str] = []

    def match(rule: str) -> None:
        matched_rules.append(rule)

    suggested_level = 4

    # CTAS 1: immediate life-threatening airway, breathing, circulation, or consciousness threats.
    if contains_any(
        text,
        [
            "cardiac arrest",
            "respiratory arrest",
            "not breathing",
            "no pulse",
            "pulseless",
            "cpr",
            "unresponsive",
            "unconscious",
            "agonal",
            "blue lips",
            "cyanosis",
        ],
    ):
        suggested_level = min(suggested_level, 1)
        match("CTAS 1 rule: possible airway, breathing, circulation, or consciousness threat.")

    if low_oxygen is not None and low_oxygen <= 88:
        suggested_level = min(suggested_level, 1)
        match(f"CTAS 1 rule: reported oxygen saturation is critically low ({low_oxygen}%).")

    if contains_any(text, ["severe respiratory distress", "can't breathe", "cannot breathe", "unable to breathe"]):
        suggested_level = min(suggested_level, 1)
        match("CTAS 1 rule: severe respiratory distress language.")

    if contains_any(text, ["uncontrolled bleeding", "massive bleeding", "severe bleeding", "hemorrhage", "shock"]):
        suggested_level = min(suggested_level, 1)
        match("CTAS 1 rule: possible shock or uncontrolled bleeding.")

    chest_pain = contains_any(text, ["chest pain", "chest pressure", "crushing chest", "tight chest"])
    chest_red_flags = contains_any(
        text,
        ["shortness of breath", "sweating", "diaphoresis", "left arm", "jaw pain", "radiating", "faint", "passed out"],
    )
    if chest_pain and chest_red_flags:
        suggested_level = min(suggested_level, 1)
        match("CTAS 1 rule: chest pain with cardiac or respiratory red flags.")

    # CTAS 2: high-risk but not clearly requiring immediate resuscitation.
    if chest_pain:
        suggested_level = min(suggested_level, 2)
        match("CTAS 2 rule: chest pain requires emergent assessment.")

    stroke_terms = ["stroke", "facial droop", "face drooping", "slurred speech", "trouble speaking", "weakness", "numbness"]
    if contains_any(text, stroke_terms) and contains_any(text, ["sudden", "new", "started", "acute", "right side", "left side"]):
        suggested_level = min(suggested_level, 2)
        match("CTAS 2 rule: possible acute stroke-like neurologic symptoms.")

    if contains_any(text, ["seizure", "convulsion", "overdose", "poisoning", "suicidal", "self harm", "violent"]):
        suggested_level = min(suggested_level, 2)
        match("CTAS 2 rule: seizure, overdose, or immediate mental health safety concern.")

    if contains_any(text, ["anaphylaxis", "throat swelling", "throat tight", "lip swelling", "tongue swelling", "hives and breathing"]):
        suggested_level = min(suggested_level, 2)
        match("CTAS 2 rule: possible anaphylaxis or airway swelling.")

    if contains_any(text, ["sepsis", "very high fever", "rigors", "confused", "confusion"]) and contains_any(
        text, ["fever", "infection", "weak", "low blood pressure", "dizzy"]
    ):
        suggested_level = min(suggested_level, 2)
        match("CTAS 2 rule: infection with systemic red flags.")

    if contains_any(text, ["pregnant", "pregnancy"]) and contains_any(text, ["bleeding", "severe pain", "abdominal pain", "faint"]):
        suggested_level = min(suggested_level, 2)
        match("CTAS 2 rule: pregnancy with bleeding, severe pain, or fainting.")

    if pain_score is not None and pain_score >= 8:
        suggested_level = min(suggested_level, 2)
        match(f"CTAS 2 rule: severe pain score reported ({pain_score}/10).")

    if low_oxygen is not None and 89 <= low_oxygen <= 92:
        suggested_level = min(suggested_level, 2)
        match(f"CTAS 2 rule: low oxygen saturation reported ({low_oxygen}%).")

    # CTAS 3: urgent symptoms that need clinician assessment but no immediate resuscitation cue.
    if contains_any(text, ["abdominal pain", "vomiting", "dehydrated", "dehydration"]) and contains_any(
        text, ["fever", "repeated", "worsening", "weak", "unable to keep fluids"]
    ):
        suggested_level = min(suggested_level, 3)
        match("CTAS 3 rule: abdominal pain, vomiting, fever, or dehydration concern.")

    if contains_any(text, ["asthma", "wheezing", "mild shortness of breath", "moderate shortness of breath"]):
        suggested_level = min(suggested_level, 3)
        match("CTAS 3 rule: respiratory symptoms without severe distress language.")

    if contains_any(text, ["head injury", "concussion"]) and not contains_any(text, ["unconscious", "seizure", "confused"]):
        suggested_level = min(suggested_level, 3)
        match("CTAS 3 rule: head injury without immediate high-risk neurologic signs.")

    if pain_score is not None and 4 <= pain_score <= 7:
        suggested_level = min(suggested_level, 3)
        match(f"CTAS 3 rule: moderate pain score reported ({pain_score}/10).")

    # CTAS 4-5: lower-acuity patterns. These only apply if no higher rule matched.
    if suggested_level >= 4 and contains_any(
        text,
        ["sore throat", "mild cough", "runny nose", "low-grade fever", "minor sprain", "minor cut", "mild rash"],
    ):
        suggested_level = 4
        match("CTAS 4 rule: mild symptoms without red-flag language.")

    if suggested_level >= 4 and contains_any(text, ["no shortness of breath", "no breathing difficulty", "able to drink", "no fever"]):
        suggested_level = min(suggested_level, 4)
        match("CTAS 4 rule: reassuring negatives reduce urgency but still need routine assessment.")

    if (
        suggested_level >= 4
        and contains_any(text, ["mild rash", "prescription refill", "medication refill", "routine", "follow up"])
        and not contains_any(text, ["fever", "swelling", "breathing", "severe pain", "chest pain"])
    ):
        suggested_level = 5
        match("CTAS 5 rule: non-urgent minor or administrative complaint without red flags.")

    if not matched_rules:
        matched_rules.append("Default CTAS 4 rule: no explicit CTAS red flags detected in text.")

    score = fallback_risk_score_from_ctas(suggested_level)
    summary = f"{request.age}-year-old patient reports: {request.symptoms.strip()}"
    reasoning = (
        "CTAS rule engine review: "
        + " ".join(matched_rules)
        + " This rule-based result is conservative decision support and should be reviewed by clinical staff."
    )
    action_by_level = {
        1: "Immediately alert clinical staff and prepare resuscitation/emergency assessment.",
        2: "Arrange emergent clinician assessment and monitor for deterioration.",
        3: "Place in queue for urgent clinician assessment and obtain basic vital signs.",
        4: "Place in queue for routine assessment; advise patient to report worsening symptoms.",
        5: "Place in non-urgent queue; provide routine assessment when available.",
    }
    return {
        "ctas_level": suggested_level,
        "urgency_label": ctas_label(suggested_level),
        "risk_score": score,
        "queue_name": queue_name_for_ctas(suggested_level),
        "clinical_summary": summary,
        "reasoning": reasoning,
        "recommended_action": action_by_level[suggested_level],
        "matched_rules": matched_rules,
        "agent_source": "ctas_rule_engine",
        "history_used": history_rows,
    }


def risk_analysis_agent(request: IntakeRequest, history_rows: List[dict]) -> dict:
    rule_result = ctas_rule_engine(request, history_rows)
    history_text = format_history_for_prompt(history_rows)
    prompt = f"""
You are the Risk Analysis Agent for an urgent care queue system.

Task:
Analyze the current patient intake together with previous database feedback.
Generate decision-support output only. Do not diagnose, prescribe treatment, or replace clinician judgment.

CTAS urgency levels:
- Level 1: Resuscitation / Critical
- Level 2: Emergent
- Level 3: Urgent
- Level 4: Less Urgent
- Level 5: Non-Urgent

Current intake:
- Patient ID: {request.patient_id or "local demo patient"}
- Name: {request.name}
- Age: {request.age}
- Symptoms: {request.symptoms}
- Optional medical history: {request.medical_history or "Not provided"}

Previous patient feedback/history from database:
{history_text}

Return valid JSON only:
{{
  "ctas_level": 1,
  "urgency_label": "Level 1: Resuscitation / Critical",
  "risk_score": 10,
  "clinical_summary": "Short neutral summary.",
  "reasoning": "3-5 sentences explaining CTAS level, risk score, prior history impact, red flags, and uncertainty.",
  "recommended_action": "Practical next staff action."
}}
"""
    try:
        result = call_deepseek_json(
            prompt,
            "Return JSON only. Be concise, cautious, and clinically conservative.",
        )
    except Exception:
        rule_result["reasoning"] = (
            f"{rule_result['reasoning']} DeepSeek was unavailable or failed, so the CTAS rule engine "
            "was used as the fallback triage support method."
        )
        return rule_result

    try:
        level = int(result["ctas_level"])
    except (KeyError, TypeError, ValueError):
        rule_result["reasoning"] = (
            f"{rule_result['reasoning']} DeepSeek returned an invalid CTAS level, so the CTAS rule engine "
            "was used as the fallback triage support method."
        )
        return rule_result

    if level not in CTAS_LEVELS:
        rule_result["reasoning"] = (
            f"{rule_result['reasoning']} DeepSeek returned unsupported CTAS level {level}, so the CTAS rule engine "
            "was used as the fallback triage support method."
        )
        return rule_result

    try:
        score = int(result.get("risk_score", fallback_risk_score_from_ctas(level)))
    except (TypeError, ValueError):
        score = fallback_risk_score_from_ctas(level)
    score = max(1, min(10, score))

    agent_source = "deepseek_risk_analysis_agent"
    rule_level = int(rule_result["ctas_level"])
    if rule_level < level:
        level = rule_level
        score = max(score, int(rule_result["risk_score"]))
        agent_source = "deepseek_risk_analysis_agent_with_ctas_rule_upgrade"
        rule_note = (
            " CTAS rule engine safety check upgraded the urgency because: "
            + " ".join(rule_result.get("matched_rules", []))
        )
    else:
        rule_note = " CTAS rule engine safety check did not require escalation beyond the LLM result."

    return {
        "ctas_level": level,
        "urgency_label": ctas_label(level),
        "risk_score": score,
        "queue_name": queue_name_for_ctas(level),
        "clinical_summary": str(result.get("clinical_summary") or rule_result["clinical_summary"]).strip(),
        "reasoning": (str(result.get("reasoning") or rule_result["reasoning"]).strip() + rule_note).strip(),
        "recommended_action": str(result.get("recommended_action") or rule_result["recommended_action"]).strip(),
        "matched_rules": rule_result.get("matched_rules", []),
        "agent_source": agent_source,
        "history_used": history_rows,
    }


def queue_prioritization_agent(patients: List[Patient]) -> dict:
    """Agent action: split active patients into three queues and sort each queue."""
    queues = {
        QUEUE_EMERGENCY: [],
        QUEUE_NORMAL: [],
        QUEUE_NON_URGENT: [],
    }
    for patient in patients:
        if patient.status not in (STATUS_WAITING, STATUS_CONSULTATION):
            continue
        queues.setdefault(patient.queue_name, []).append(patient)

    for name, rows in queues.items():
        rows.sort(key=lambda patient: (patient.ctas_level, -patient.risk_score, parse_dt(patient.checked_in_at)))
        queues[name] = [serialize_patient(patient) for patient in rows]

    return queues


def summary_payload(patients: List[Patient], completed: List[Patient]) -> dict:
    ctas_counts = {str(level): 0 for level in CTAS_LEVELS}
    for patient in patients + completed:
        ctas_counts[str(patient.ctas_level)] += 1
    total_patients = len(patients) + len(completed)
    return {
        "total": total_patients,
        "total_patients": total_patients,
        "waiting": sum(1 for patient in patients if patient.status == STATUS_WAITING),
        "in_consultation": sum(1 for patient in patients if patient.status == STATUS_CONSULTATION),
        "completed": len(completed),
        "ctas_counts": ctas_counts,
    }


def get_patient_or_404(patient_id: int, patients: List[Patient]) -> Patient:
    for patient in patients:
        if patient.id == patient_id:
            return patient
    raise HTTPException(status_code=404, detail="Patient not found.")


def patient_access_token(patient: Patient) -> str:
    return f"patient-{patient.id}-{patient.patient_id}"


def estimated_wait_range(patients_ahead: int) -> str:
    low = patients_ahead * 10
    high = low + 15
    if patients_ahead == 0:
        return "Soon / next available"
    return f"{low}-{high} minutes"


def patient_status_payload(patient: Patient) -> dict:
    patients = load_patients()
    completed = load_completed_patients()
    queue_number = None
    patients_ahead = 0

    if patient.status != STATUS_COMPLETED:
        global_queue = [
            row
            for row in patients
            if row.status in (STATUS_WAITING, STATUS_CONSULTATION)
        ]
        global_queue.sort(
            key=lambda row: (
                row.ctas_level,
                -row.risk_score,
                parse_dt(row.checked_in_at),
            )
        )
        for index, row in enumerate(global_queue, start=1):
            if row.id == patient.id:
                queue_number = index
                patients_ahead = max(0, index - 1)
                break

    return {
        "local_patient_id": patient.id,
        "patient_id": patient.patient_id,
        "queue_number": queue_number,
        "status": patient.status,
        "patients_ahead": patients_ahead,
        "estimated_wait_range": estimated_wait_range(patients_ahead),
        "notified": bool(patient.notified_at) or patient.status == STATUS_CONSULTATION,
        "notified_at": patient.notified_at,
        "checked_in_at": patient.checked_in_at,
        "server_time": now_iso(),
        "access_token": patient_access_token(patient),
        "submitted_information": {
            "name": patient.name,
            "age": patient.age,
            "symptoms": patient.symptoms,
            "medical_history": patient.medical_history,
            "ctas_urgency_level": patient.ctas_level,
            "risk_score": patient.risk_score,
            "queue_name": patient.queue_name,
            "clinical_summary": patient.clinical_summary,
            "recommended_action": patient.recommended_action,
        },
    }


def find_patient_anywhere(local_patient_id: int) -> Patient:
    patients = load_patients()
    completed = load_completed_patients()
    return get_patient_or_404(local_patient_id, patients + completed)


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "backend_version": BACKEND_VERSION,
        "deepseek_configured": bool(DEEPSEEK_API_KEY),
        "database_api_url": DATABASE_API_URL,
        "healthcare_records_table": HEALTHCARE_RECORDS_TABLE,
        "feedback_table": FEEDBACK_TABLE,
        "patients_registration_table": PATIENTS_REGISTRATION_TABLE,
        "medical_history_table": MEDICAL_HISTORY_TABLE,
    }


@app.get("/ctas-levels")
def get_ctas_levels() -> dict:
    return CTAS_LEVELS


@app.get("/patient/{patient_id}/history")
def get_patient_history(patient_id: int) -> dict:
    return {"patient_id": patient_id, "history": fetch_patient_history(patient_id)}


@app.post("/patient/check-in")
def patient_app_check_in(request: IntakeRequest) -> dict:
    try:
        result = intake(request)
        if not result.get("database", {}).get("saved_to_database"):
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "Check-in analysis completed, but the visit record was not saved to healthcare_records.",
                    "database": result.get("database"),
                    "registration_database": result.get("registration_database"),
                },
            )
        patient_row = result["patient"]
        try:
            patient = find_patient_anywhere(int(patient_row["id"]))
        except HTTPException:
            patient = patient_from_dict(patient_row)
        return {
            "message": "Check-in complete.",
            "patient": patient_status_payload(patient),
            "analysis": result.get("analysis"),
            "database": result.get("database"),
        }
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail={
                "error": f"Patient app check-in failed: {type(exc).__name__}: {exc}",
                "traceback": traceback.format_exc(),
            },
        ) from exc


@app.get("/patient/{local_patient_id}/status")
def patient_app_status(local_patient_id: int) -> dict:
    patient = find_patient_anywhere(local_patient_id)
    return {"patient": patient_status_payload(patient)}


@app.post("/patient/{local_patient_id}/feedback")
def patient_app_feedback(local_patient_id: int, payload: dict) -> dict:
    patient = find_patient_anywhere(local_patient_id)
    raw_message = str(payload.get("message", "")).strip()
    rating = str(payload.get("rating", "Unsure")).strip() or "Unsure"
    condition_update = str(payload.get("condition_update", "")).strip()
    feedback_message = str(payload.get("feedback_message", "")).strip()

    if raw_message.startswith("[CONDITION_UPDATE]"):
        condition_update = raw_message.replace("[CONDITION_UPDATE]", "", 1).strip()
    elif raw_message.startswith("[APP_FEEDBACK]"):
        feedback_message = raw_message.replace("[APP_FEEDBACK]", "", 1).strip()
    elif not feedback_message:
        feedback_message = raw_message

    request = FeedbackRequest(
        patient_id=patient.patient_id,
        rating=rating,
        message=feedback_message,
        condition_update=condition_update,
        ctas_level=patient.ctas_level,
        risk_score=patient.risk_score,
    )
    result = save_feedback(request)
    return {
        "message": result["alert_agent"].get("patient_message") or "Your update was submitted.",
        "feedback": result.get("feedback"),
        "alert_agent": result.get("alert_agent"),
        "database": result.get("database"),
    }


@app.post("/intake")
def intake(request: IntakeRequest) -> dict:
    patients = load_patients()
    completed = load_completed_patients()
    local_id = next_local_id(patients, completed)
    database_patient_id = request.patient_id or local_id
    check_in_time = now_iso()
    registration_result = ensure_patient_registration(
        database_patient_id, request.name, request.age, request.gender
    )

    request_with_id = request.copy(update={"patient_id": database_patient_id})
    history_rows = fetch_patient_history(database_patient_id)
    analysis = risk_analysis_agent(request_with_id, history_rows)

    patient = Patient(
        id=local_id,
        patient_id=database_patient_id,
        name=request.name.strip(),
        age=request.age,
        symptoms=request.symptoms.strip(),
        medical_history=request.medical_history.strip(),
        ctas_level=analysis["ctas_level"],
        risk_score=analysis["risk_score"],
        queue_name=analysis["queue_name"],
        clinical_summary=analysis["clinical_summary"],
        reasoning=analysis["reasoning"],
        recommended_action=analysis["recommended_action"],
        checked_in_at=check_in_time,
    )
    database_result = create_healthcare_record(patient)
    medical_history_result = save_medical_history_note(patient)
    patients.append(patient)
    local_storage_result = {"saved_locally": False, "skipped": True}
    if not database_result.get("saved_to_database"):
        local_storage_result = try_save_patients(patients)

    return {
        "message": "Risk Analysis Agent completed. Queue Prioritization Agent assigned the patient.",
        "patient": serialize_patient(patient),
        "analysis": analysis,
        "queues": queue_prioritization_agent(patients),
        "summary": summary_payload(patients, completed),
        "registration_database": registration_result,
        "database": database_result,
        "medical_history_database": medical_history_result,
        "local_storage": local_storage_result,
    }


@app.get("/queues")
def get_queues() -> dict:
    patients = load_patients()
    completed = load_completed_patients()
    return {
        "summary": summary_payload(patients, completed),
        "queues": queue_prioritization_agent(patients),
    }


@app.get("/patients")
def get_patients() -> dict:
    patients = load_patients()
    completed = load_completed_patients()
    return {
        "active": [serialize_patient(patient) for patient in patients],
        "completed": [serialize_patient(patient) for patient in completed],
    }


@app.get("/feedback")
def get_local_feedback() -> dict:
    try:
        return {"feedback": db_get_table(FEEDBACK_TABLE)}
    except Exception:
        return {"feedback": load_json_list(LOCAL_FEEDBACK_FILE)}


@app.get("/alerts")
def get_feedback_alerts() -> dict:
    try:
        rows = db_get_table(FEEDBACK_TABLE)
        records = db_get_table(HEALTHCARE_RECORDS_TABLE)
        patient_by_record = {
            str(row.get("record_id")): row.get("patient_id")
            for row in records
            if row.get("record_id") is not None
        }
        local_alerts = load_json_list(ALERT_FILE)
        alerts = list(local_alerts)
        seen = {feedback_alert_display_key(alert) for alert in alerts}
        for row in rows:
            if str(row.get("alert_required")).lower() not in {"true", "1", "yes"}:
                continue
            severity = row.get("alert_severity") or "needs review"
            database_alert = {
                **row,
                "patient_id": patient_by_record.get(str(row.get("record_id")), "Unknown"),
                "severity": severity,
                "alert_severity": severity,
                "alert_reason": row.get("alert_reason", "No alert reason provided."),
                "agent_source": row.get("agent_source", "database_feedback_alert_record"),
                "agent_decision_summary": (
                    "Feedback Alert Agent decision: staff alert required. "
                    f"Severity: {severity}. "
                    f"Reason: {row.get('alert_reason', 'No alert reason provided.')}"
                ),
                "recommended_staff_action": (
                    "Ask clinical staff to review this feedback and reassess the patient if needed."
                ),
                "datetime": row.get("created_time"),
                "feedback": row.get("feedback_message", ""),
            }
            key = feedback_alert_display_key(database_alert)
            if key not in seen:
                alerts.append(database_alert)
                seen.add(key)
        return {"alerts": alerts}
    except Exception:
        return {"alerts": load_json_list(ALERT_FILE)}


@app.post("/patient/{local_patient_id}/notify")
def notify_patient(local_patient_id: int) -> dict:
    patients = load_patients()
    patient = get_patient_or_404(local_patient_id, patients)
    patient.notified_at = now_iso()
    save_patients(patients)
    return {"message": "Patient notified.", "patient": serialize_patient(patient)}


@app.post("/patient/{local_patient_id}/start")
def start_consultation(local_patient_id: int) -> dict:
    patients = load_patients()
    patient = get_patient_or_404(local_patient_id, patients)
    patient.status = STATUS_CONSULTATION
    patient.consultation_started_at = now_iso()
    database_result = update_healthcare_record(
        patient.id,
        {"status": patient.status, "consultation_started_at": patient.consultation_started_at},
    )
    if not database_result.get("updated_database"):
        save_patients(patients)
    return {"message": "Consultation started.", "patient": serialize_patient(patient), "database": database_result}


@app.post("/patient/{local_patient_id}/complete")
def complete_patient(local_patient_id: int) -> dict:
    patients = load_patients()
    completed = load_completed_patients()
    patient = get_patient_or_404(local_patient_id, patients)
    patient.status = STATUS_COMPLETED
    patient.completed_at = now_iso()
    database_result = update_healthcare_record(
        patient.id,
        {"status": patient.status, "completed_at": patient.completed_at},
    )
    patients = [row for row in patients if row.id != local_patient_id]
    completed.append(patient)
    if not database_result.get("updated_database"):
        save_patients(patients)
        save_completed_patients(completed)
    return {
        "message": "Patient marked as completed/discharged.",
        "patient": serialize_patient(patient),
        "summary": summary_payload(patients, completed),
        "database": database_result,
    }


@app.post("/feedback")
def save_feedback(request: FeedbackRequest) -> dict:
    feedback_text = request.message.strip()
    condition_text = request.condition_update.strip()
    linked_record = current_record_for_patient(request.patient_id)
    record_id = linked_record.id if linked_record else None
    ctas_level = request.ctas_level or (linked_record.ctas_level if linked_record else None)
    risk_score = request.risk_score or (linked_record.risk_score if linked_record else None)
    alert_request = request.copy(update={"ctas_level": ctas_level, "risk_score": risk_score})
    alert = feedback_alert_agent(alert_request)
    agent_decision_summary = (
        f"Feedback Alert Agent decision: "
        f"{'staff alert required' if alert.alert_required else 'no immediate staff alert required'}. "
        f"Severity: {alert.severity}. Reason: {alert.alert_reason}"
    )
    database_feedback = {
        "record_id": record_id,
        "rating": request.rating,
        "feedback_message": feedback_text,
        "condition_update": condition_text,
        "alert_required": str(alert.alert_required).lower(),
        "alert_reason": alert.alert_reason,
        "created_time": now_database_text(),
    }
    local_feedback = {
        **database_feedback,
        "risk_score": risk_score,
        "alert_agent": alert.dict(),
        "agent_decision_summary": agent_decision_summary,
    }
    database_result = save_feedback_to_database(database_feedback, local_feedback)

    alert_record = None
    if alert.alert_required:
        alert_record = {
            "patient_id": request.patient_id,
            "record_id": record_id,
            "datetime": database_feedback["created_time"],
            "rating": request.rating,
            "ctas_level": ctas_level,
            "risk_score": risk_score,
            "feedback": feedback_text,
            "condition_update": condition_text,
            "agent_decision_summary": agent_decision_summary,
            **alert.dict(),
        }
        save_feedback_alert(alert_record)

    return {
        "message": "Feedback saved and analyzed by the Feedback Alert Agent.",
        "feedback": local_feedback,
        "alert_agent": alert.dict(),
        "alert": alert_record,
        "database": database_result,
    }
