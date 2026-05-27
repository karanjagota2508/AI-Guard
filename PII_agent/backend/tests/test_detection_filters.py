import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from detection_filters import filter_detected_entities


class DetectionFilterTests(unittest.TestCase):
    def test_filters_generic_person_false_positive(self):
        text = "PII detection ho gya"
        detected = [
            {
                "entity_type": "PERSON",
                "start": 14,
                "end": 20,
                "score": 0.85,
            }
        ]

        self.assertEqual(filter_detected_entities(text, detected), [])

    def test_filters_hi_like_small_talk_false_positives(self):
        samples = [
            ("Hi", "PERSON", 0, 2, 0.99),
            ("hello", "PERSON", 0, 5, 0.95),
            ("ok", "LOCATION", 0, 2, 0.93),
        ]

        for text, entity_type, start, end, score in samples:
            with self.subTest(text=text, entity_type=entity_type):
                detected = [
                    {
                        "entity_type": entity_type,
                        "start": start,
                        "end": end,
                        "score": score,
                    }
                ]
                self.assertEqual(filter_detected_entities(text, detected), [])

    def test_keeps_real_email_detection(self):
        text = "email me at test@example.com"
        detected = [
            {
                "entity_type": "EMAIL_ADDRESS",
                "start": 12,
                "end": 28,
                "score": 0.99,
            }
        ]

        self.assertEqual(filter_detected_entities(text, detected), detected)

    def test_keeps_representative_sensitive_entities(self):
        samples = [
            (
                "Call me at 415-555-1212",
                {
                    "entity_type": "PHONE_NUMBER",
                    "start": 11,
                    "end": 23,
                    "score": 0.99,
                },
            ),
            (
                "SSN 123-45-6789",
                {
                    "entity_type": "US_SSN",
                    "start": 4,
                    "end": 15,
                    "score": 0.99,
                },
            ),
            (
                "Bank account 323480298721",
                {
                    "entity_type": "US_BANK_NUMBER",
                    "start": 13,
                    "end": 25,
                    "score": 0.99,
                },
            ),
        ]

        for text, detection in samples:
            with self.subTest(text=text, entity_type=detection["entity_type"]):
                self.assertEqual(filter_detected_entities(text, [detection]), [detection])

    def test_keeps_confident_full_name_detection(self):
        text = "Customer name is Karan Jagota"
        detected = [
            {
                "entity_type": "PERSON",
                "start": 17,
                "end": 29,
                "score": 0.97,
            }
        ]

        self.assertEqual(filter_detected_entities(text, detected), detected)

    def test_filters_lowercase_location_false_positive(self):
        text = "please route this to new town quickly"
        detected = [
            {
                "entity_type": "LOCATION",
                "start": 21,
                "end": 29,
                "score": 0.92,
            }
        ]

        self.assertEqual(filter_detected_entities(text, detected), [])


if __name__ == "__main__":
    unittest.main()
