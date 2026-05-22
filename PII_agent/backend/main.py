import os
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from presidio_analyzer import AnalyzerEngine, RecognizerResult
from presidio_analyzer.nlp_engine import NlpEngineProvider
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig
from pydantic import BaseModel

from detection_filters import build_detect_entity_list, filter_detected_entities


DEFAULT_ALLOWED_ORIGINS = "http://127.0.0.1,http://localhost"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000


def parse_allowed_origins() -> List[str]:
    raw_value = os.getenv("PII_SERVICE_CORS_ORIGINS", DEFAULT_ALLOWED_ORIGINS)
    origins = [origin.strip() for origin in raw_value.split(",") if origin.strip()]
    return origins or [DEFAULT_ALLOWED_ORIGINS]


app = FastAPI(title="Ultibot PII Agent")

app.add_middleware(
    CORSMiddleware,
    allow_origins=parse_allowed_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def create_analyzer() -> AnalyzerEngine:
    configuration = {
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": "en_core_web_lg"}],
    }
    provider = NlpEngineProvider(nlp_configuration=configuration)
    nlp_engine = provider.create_engine()
    return AnalyzerEngine(nlp_engine=nlp_engine, supported_languages=["en"])


analyzer = create_analyzer()
anonymizer = AnonymizerEngine()


class PiiDetectRequest(BaseModel):
    text: str
    score_threshold: float = 0.35
    entities: Optional[List[str]] = None


class GlobalOperatorConfig(BaseModel):
    type: str = "keep"
    masking_char: str = "*"
    chars_to_mask: int = 0
    from_end: bool = False
    new_value: str = "<REDACTED>"
    hash_type: str = "sha256"


class PiiAnonymizeRequest(BaseModel):
    text: str
    detect_results: List[Dict[str, Any]]
    global_operator: Optional[GlobalOperatorConfig] = None


def normalize_operator_type(value: Optional[str]) -> str:
    normalized = (value or "").strip().lower()
    if not normalized:
        return "keep"

    if normalized in ("block", "blocked"):
        return "replace"

    return normalized


def build_operator(config: Optional[GlobalOperatorConfig]) -> OperatorConfig:
    if config is None:
        return OperatorConfig("keep", {})

    operator_type = normalize_operator_type(config.type)
    if operator_type == "mask":
        chars_to_mask = config.chars_to_mask if config.chars_to_mask > 0 else 100
        return OperatorConfig(
            "mask",
            {
                "type": "mask",
                "masking_char": config.masking_char,
                "chars_to_mask": chars_to_mask,
                "from_end": config.from_end,
            },
        )

    if operator_type == "replace":
        new_value = config.new_value.strip() if config.new_value.strip() else "<REDACTED>"
        return OperatorConfig("replace", {"new_value": new_value})

    if operator_type == "redact":
        return OperatorConfig("redact", {})

    if operator_type == "hash":
        hash_type = config.hash_type.strip().lower() if config.hash_type.strip() else "sha256"
        return OperatorConfig("hash", {"hash_type": hash_type})

    return OperatorConfig("keep", {})


def detect_entities(req: PiiDetectRequest) -> List[Dict[str, Any]]:
    entities = build_detect_entity_list(req.entities)
    results = analyzer.analyze(
        text=req.text,
        language="en",
        score_threshold=req.score_threshold,
        entities=entities,
    )
    detected = [
        {
            "entity_type": result.entity_type,
            "start": result.start,
            "end": result.end,
            "score": result.score,
        }
        for result in results
    ]
    return filter_detected_entities(req.text, detected)


def classify_severity(detected: List[Dict[str, Any]]) -> str:
    severity = "low"
    critical_entities = {
        "CREDIT_CARD",
        "CRYPTO",
        "IBAN_CODE",
        "US_BANK_NUMBER",
        "US_ITIN",
        "US_PASSPORT",
        "PASSWORD",
    }
    medium_entities = {
        "EMAIL_ADDRESS",
        "PHONE_NUMBER",
        "US_SSN",
        "IP_ADDRESS",
        "PERSON",
        "LOCATION",
        "MEDICAL_LICENSE",
        "DRIVER_LICENSE",
    }

    for item in detected:
        entity_type = str(item.get("entity_type", "")).upper()
        if entity_type in critical_entities:
            return "critical"
        if entity_type in medium_entities:
            severity = "medium"

    return severity


def anonymize_detected_text(
    text: str,
    detect_results: List[Dict[str, Any]],
    operator_config: Optional[GlobalOperatorConfig] = None,
) -> Dict[str, Any]:
    recognizer_results = [
        RecognizerResult(
            entity_type=result.get("entity_type"),
            start=result.get("start"),
            end=result.get("end"),
            score=result.get("score"),
        )
        for result in detect_results
    ]

    operator = build_operator(operator_config)
    response = anonymizer.anonymize(
        text=text,
        analyzer_results=recognizer_results,
        operators={"DEFAULT": operator},
    )

    return {
        "text": response.text,
        "items": [
            {
                "entity_type": item.entity_type,
                "start": item.start,
                "end": item.end,
                "operator": item.operator,
            }
            for item in response.items
        ],
    }


@app.get("/")
async def root():
    return {"service": "pii_agent", "status": "ok"}


@app.get("/health")
async def health():
    return {"status": "healthy"}


@app.get("/healthz")
async def healthz():
    return {"ok": True}


@app.post("/api/pii/detect")
async def detect_pii(req: PiiDetectRequest):
    try:
        return {"detected": detect_entities(req)}
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error


@app.post("/api/pii/anonymize")
async def anonymize_pii(req: PiiAnonymizeRequest):
    try:
        return anonymize_detected_text(req.text, req.detect_results, req.global_operator)
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error


@app.post("/detect")
async def detect_decision(req: PiiDetectRequest):
    try:
        detected = detect_entities(req)
        if not detected:
            return {
                "contains_pii": False,
                "severity": "low",
                "action": "allow",
                "redacted_text": req.text,
                "detected": [],
            }

        severity = classify_severity(detected)
        action = "block" if severity == "critical" else "redact"
        redacted_text = ""
        if action == "redact":
            redacted_text = anonymize_detected_text(
                req.text,
                detected,
                GlobalOperatorConfig(type="replace", new_value="<REDACTED>"),
            )["text"]

        return {
            "contains_pii": True,
            "severity": severity,
            "action": action,
            "redacted_text": redacted_text,
            "detected": detected,
        }
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error


@app.post("/anonymize")
async def anonymize_legacy(req: PiiAnonymizeRequest):
    return await anonymize_pii(req)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=os.getenv("HOST", DEFAULT_HOST),
        port=int(os.getenv("PORT", str(DEFAULT_PORT))),
        reload=os.getenv("PII_SERVICE_RELOAD", "false").strip().lower() == "true",
    )
