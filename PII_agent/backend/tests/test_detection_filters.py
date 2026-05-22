import unittest

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
