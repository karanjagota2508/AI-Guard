import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sys
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from main import PII_READINESS, app


class MainApiTests(unittest.TestCase):
    def setUp(self):
        self.warmup_patcher = patch("main.warmup_pii_engine")
        self.warmup_patcher.start()
        self.addCleanup(self.warmup_patcher.stop)
        PII_READINESS.mark_ready()
        self.client = TestClient(app)

    def tearDown(self):
        self.client.close()

    @patch("main.detect_entities")
    def test_api_detect_returns_detected_payload(self, detect_entities):
        detect_entities.return_value = [
            {
                "entity_type": "EMAIL_ADDRESS",
                "start": 12,
                "end": 28,
                "score": 0.99,
            }
        ]

        response = self.client.post("/api/pii/detect", json={"text": "email me at test@example.com"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()["detected"]), 1)

    def test_readyz_returns_503_until_warmup_succeeds(self):
        PII_READINESS.mark_unready("PII analyzer warmup has not completed yet.")

        not_ready = self.client.get("/readyz")
        self.assertEqual(not_ready.status_code, 503)
        self.assertEqual(not_ready.json()["ok"], False)

        PII_READINESS.mark_ready()
        ready = self.client.get("/readyz")
        self.assertEqual(ready.status_code, 200)
        self.assertEqual(ready.json()["ok"], True)

    @patch("main.get_ready_analyzer")
    def test_api_detect_filters_hi_false_positive(self, get_ready_analyzer):
        get_ready_analyzer.return_value = SimpleNamespace(
            analyze=lambda **_kwargs: [
                SimpleNamespace(
                    entity_type="PERSON",
                    start=0,
                    end=2,
                    score=0.99,
                )
            ]
        )

        response = self.client.post("/api/pii/detect", json={"text": "Hi"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["detected"], [])

    @patch("main.get_ready_analyzer")
    def test_api_detect_keeps_representative_real_pii(self, get_ready_analyzer):
        detections = [
            ("test@example.com", "EMAIL_ADDRESS", 0, 16),
            ("415-555-1212", "PHONE_NUMBER", 0, 12),
            ("123-45-6789", "US_SSN", 0, 11),
            ("323480298721", "US_BANK_NUMBER", 0, 12),
        ]

        for text, entity_type, start, end in detections:
            with self.subTest(entity_type=entity_type):
                get_ready_analyzer.return_value = SimpleNamespace(
                    analyze=lambda **_kwargs: [
                        SimpleNamespace(
                            entity_type=entity_type,
                            start=start,
                            end=end,
                            score=0.99,
                        )
                    ]
                )

                response = self.client.post("/api/pii/detect", json={"text": text})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(len(response.json()["detected"]), 1)
                self.assertEqual(response.json()["detected"][0]["entity_type"], entity_type)

    @patch("main.anonymize_detected_text")
    def test_api_anonymize_returns_redacted_text(self, anonymize_detected_text):
        anonymize_detected_text.return_value = {"text": "email me at <REDACTED>"}

        response = self.client.post(
            "/api/pii/anonymize",
            json={
                "text": "email me at test@example.com",
                "detect_results": [
                    {
                        "entity_type": "EMAIL_ADDRESS",
                        "start": 12,
                        "end": 28,
                        "score": 0.99,
                    }
                ],
                "global_operator": {"type": "replace", "new_value": "<REDACTED>"},
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["text"], "email me at <REDACTED>")

    @patch("main.anonymize_detected_text")
    @patch("main.detect_entities")
    def test_legacy_detect_redacts_medium_pii(self, detect_entities, anonymize_detected_text):
        detect_entities.return_value = [
            {
                "entity_type": "EMAIL_ADDRESS",
                "start": 12,
                "end": 28,
                "score": 0.99,
            }
        ]
        anonymize_detected_text.return_value = {"text": "email me at <REDACTED>"}

        response = self.client.post("/detect", json={"text": "email me at test@example.com"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["action"], "redact")
        self.assertEqual(response.json()["redacted_text"], "email me at <REDACTED>")

    @patch("main.detect_entities")
    def test_legacy_detect_blocks_critical_pii(self, detect_entities):
        detect_entities.return_value = [
            {
                "entity_type": "CREDIT_CARD",
                "start": 0,
                "end": 16,
                "score": 0.99,
            }
        ]

        response = self.client.post("/detect", json={"text": "4111111111111111"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["action"], "block")
        self.assertEqual(response.json()["redacted_text"], "")


if __name__ == "__main__":
    unittest.main()
