export type PiiComplianceSettings = {
  blockEmailAddresses: boolean;
  blockCreditCards: boolean;
  blockSocialSecurityNumbers: boolean;
  blockPhoneNumbers: boolean;
  blacklistTerms: string[];
  customRegexPatterns: string[];
  enableRealTimePiiDetection: boolean;
  caseSensitive: boolean;
  presidioMode?: "STRICT" | "NORMAL" | "RELAXED";
  presidioThreshold?: number;
  presidioEntities?: string[];
  presidioAnonymizationMode?: string;
};

export type PiiDetectionResult = {
  entity_type: string;
  start: number;
  end: number;
  score: number;
};

type DetectResponse = {
  detected?: PiiDetectionResult[];
};

type AnonymizeResponse = {
  text?: string;
};

type PiiRequestOptions = {
  signal?: AbortSignal;
};

type AnonymizeOptions = PiiRequestOptions & {
  detected?: PiiDetectionResult[];
};

const csrfHeaderName = "X-CSRF-Token";

const ALLOWED_PRESIDIO_ENTITIES = new Set([
  "AGE",
  "CREDIT_CARD",
  "CRYPTO",
  "EMAIL",
  "EMAIL_ADDRESS",
  "IBAN_CODE",
  "ID",
  "IN_AADHAAR",
  "IN_PAN",
  "IP_ADDRESS",
  "LOCATION",
  "MEDICAL_LICENSE",
  "NRP",
  "PHONE_NUMBER",
  "US_BANK_NUMBER",
  "US_DRIVER_LICENSE",
  "US_ITIN",
  "US_PASSPORT",
  "US_SSN",
]);

function normalizeOperatorType(mode?: string) {
  const normalized = mode?.trim().toLowerCase();
  if (!normalized) {
    return "keep";
  }

  if (normalized === "block" || normalized === "blocked") {
    return "replace";
  }

  return normalized;
}

function getPresidioThreshold(
  mode?: "STRICT" | "NORMAL" | "RELAXED",
  overrideThreshold?: number,
) {
  if (overrideThreshold !== undefined) {
    return overrideThreshold;
  }

  switch (mode) {
    case "STRICT":
      return 0.25;
    case "RELAXED":
      return 0.6;
    case "NORMAL":
    default:
      return 0.35;
  }
}

function buildPresidioEntities(config: PiiComplianceSettings) {
  if (config.presidioEntities && config.presidioEntities.length > 0) {
    return config.presidioEntities.filter((entity) =>
      ALLOWED_PRESIDIO_ENTITIES.has(entity),
    );
  }

  const entities: string[] = [];

  if (config.blockEmailAddresses) {
    entities.push("EMAIL_ADDRESS");
  }

  if (config.blockCreditCards) {
    entities.push("CREDIT_CARD");
    entities.push("IBAN_CODE");
    entities.push("US_BANK_NUMBER");
  }

  if (config.blockSocialSecurityNumbers) {
    entities.push("US_SSN");
    entities.push("US_PASSPORT");
  }

  if (config.blockPhoneNumbers) {
    entities.push("PHONE_NUMBER");
    entities.push("US_BANK_NUMBER");
  }

  return [...new Set(entities)];
}

function readCookie(name: string) {
  if (typeof document === "undefined") {
    return null;
  }

  const encodedName = `${encodeURIComponent(name)}=`;
  const segment = document.cookie
    .split("; ")
    .find((entry) => entry.startsWith(encodedName));

  return segment ? decodeURIComponent(segment.slice(encodedName.length)) : null;
}

async function requestPiiService<T>(
  path: string,
  body: Record<string, unknown>,
  options?: PiiRequestOptions,
): Promise<T | null> {
  try {
    const headers = new Headers({ "Content-Type": "application/json" });
    const csrfToken = readCookie("gg_csrf");
    if (csrfToken) {
      headers.set(csrfHeaderName, csrfToken);
    }

    const response = await fetch(path, {
      method: "POST",
      credentials: "include",
      headers,
      body: JSON.stringify(body),
      signal: options?.signal,
    });

    if (!response.ok) {
      return null;
    }

    return (await response.json()) as T;
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      return null;
    }

    console.debug("PII service request failed", error);
    return null;
  }
}

let lastDetectCacheKey: string | null = null;
let lastDetectCacheValue: PiiDetectionResult[] = [];

function buildDetectCacheKey(text: string, config: PiiComplianceSettings) {
  const normalizedText = text.trim().toLowerCase();
  const entities = buildPresidioEntities(config);
  const threshold = getPresidioThreshold(
    config.presidioMode,
    config.presidioThreshold,
  );

  return JSON.stringify({
    text: normalizedText,
    threshold,
    entities,
  });
}

export function buildSensitiveWarning(detected: PiiDetectionResult[]) {
  if (detected.length === 0) {
    return null;
  }

  const topEntity = [...detected].sort((left, right) => right.score - left.score)[0];
  return `Sensitive information detected: ${topEntity.entity_type}`;
}

export async function detectPII(
  text: string,
  config: PiiComplianceSettings,
  options?: PiiRequestOptions,
) {
  const entities = buildPresidioEntities(config);
  if (entities.length === 0) {
    return [];
  }

  const cacheKey = buildDetectCacheKey(text, config);
  if (cacheKey === lastDetectCacheKey) {
    return lastDetectCacheValue;
  }

  const response = await requestPiiService<DetectResponse>("/api/pii/detect", {
    text: text.toLowerCase(),
    score_threshold: getPresidioThreshold(
      config.presidioMode,
      config.presidioThreshold,
    ),
    entities,
  }, options);

  if (!response) {
    return [];
  }

  const detected = response.detected ?? [];
  lastDetectCacheKey = cacheKey;
  lastDetectCacheValue = detected;
  return detected;
}

export async function detectSensitiveInput(
  value: string,
  compliance: PiiComplianceSettings,
  options?: PiiRequestOptions,
) {
  if (!value.trim() || !compliance.enableRealTimePiiDetection) {
    return { warning: null, isBlocking: false };
  }

  const detected = await detectPII(value, compliance, options);
  const warning = buildSensitiveWarning(detected);
  const isBlocking = detected.some(
    (item) => item.entity_type !== "EMAIL_ADDRESS" && item.entity_type !== "EMAIL"
  );

  return { warning, isBlocking };
}

export async function anonymizeSensitiveInput(
  text: string,
  config: PiiComplianceSettings,
  options?: AnonymizeOptions,
): Promise<string> {
  const operatorType = normalizeOperatorType(config.presidioAnonymizationMode);
  if (
    !text.trim() ||
    !config.enableRealTimePiiDetection ||
    operatorType === "keep"
  ) {
    return text;
  }

  let detected = options?.detected ?? await detectPII(text, config, options);
  
  // Never block or redact email addresses
  detected = detected.filter((item) => item.entity_type !== "EMAIL_ADDRESS" && item.entity_type !== "EMAIL");

  if (detected.length === 0) {
    return text;
  }

  const response = await requestPiiService<AnonymizeResponse>(
    "/api/pii/anonymize",
    {
      text,
      detect_results: detected,
      global_operator: {
        type: operatorType,
        masking_char: "*",
        chars_to_mask: 100,
        from_end: false,
        new_value: "<REDACTED>",
        hash_type: "sha256",
      },
    },
    options,
  );

  return response?.text ?? text;
}
