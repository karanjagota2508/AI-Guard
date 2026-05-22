import re
from typing import Any, Dict, Iterable, List, Optional


DEFAULT_DETECT_ENTITIES = [
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "US_SSN",
    "CREDIT_CARD",
    "CRYPTO",
    "IBAN_CODE",
    "US_BANK_NUMBER",
    "US_ITIN",
    "US_PASSPORT",
    "IP_ADDRESS",
    "PASSWORD",
    "MEDICAL_LICENSE",
    "DRIVER_LICENSE",
    "PERSON",
    "LOCATION",
]

GENERIC_FALSE_POSITIVE_SPANS = {
    "hi",
    "hello",
    "hey",
    "ok",
    "okay",
    "done",
    "test",
    "thanks",
    "thank you",
    "ho gya",
    "ho gaya",
}

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'’-]*")


def build_detect_entity_list(entities: Optional[Iterable[str]]) -> List[str]:
    if entities:
        normalized = [str(entity).strip().upper() for entity in entities if str(entity).strip()]
        return list(dict.fromkeys(normalized))

    return list(DEFAULT_DETECT_ENTITIES)


def filter_detected_entities(
    text: str,
    detections: Iterable[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    filtered: List[Dict[str, Any]] = []
    for item in detections:
        if should_keep_detection(text, item):
            filtered.append(item)
    return filtered


def should_keep_detection(text: str, detection: Dict[str, Any]) -> bool:
    entity_type = str(detection.get("entity_type", "")).upper()
    start = int(detection.get("start", 0) or 0)
    end = int(detection.get("end", 0) or 0)
    score = float(detection.get("score", 0.0) or 0.0)

    if end <= start or start < 0 or end > len(text):
        return False

    span = normalize_span(text[start:end])
    if not span:
        return False

    if span.lower() in GENERIC_FALSE_POSITIVE_SPANS:
        return False

    if entity_type == "PERSON":
        return is_confident_person_span(span, score)

    if entity_type == "LOCATION":
        return is_confident_location_span(span, score)

    return True


def normalize_span(span: str) -> str:
    return re.sub(r"\s+", " ", span.strip())


def is_confident_person_span(span: str, score: float) -> bool:
    if score < 0.92:
        return False

    words = WORD_RE.findall(span)
    if not words:
        return False

    if len(words) >= 2:
        significant_words = [word for word in words if len(word) >= 2]
        return (
            len(significant_words) >= 2
            and sum(len(word) for word in significant_words) >= 5
            and all(word[0].isupper() for word in significant_words)
        )

    word = words[0]
    return word[0].isupper() and len(word) >= 5


def is_confident_location_span(span: str, score: float) -> bool:
    if score < 0.9:
        return False

    words = WORD_RE.findall(span)
    if not words:
        return False

    has_uppercase = any(any(char.isupper() for char in word) for word in words)
    return has_uppercase and sum(len(word) for word in words) >= 4
