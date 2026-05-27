export type GuardMode = "idle" | "active";

export type ScanAction = "allow" | "block" | "redact";
export type ScanDecisionKind = "clean" | "pii_detected" | "scan_error";

export interface ScanRequest {
  text: string;
}

export interface ScanResponse {
  action: ScanAction;
  decision_kind: ScanDecisionKind;
  redacted_text: string;
  reason: string;
  detected_entity?: string | null;
}

export interface ActivityRequest {
  page_url: string;
  tab_visible: boolean;
}

export interface StatusResponse {
  mode: GuardMode;
  active_sources: string[];
  blocked_hosts: string[];
}

export interface NativeHelloResponse {
  type: "hello";
  token: string;
  base_url: string;
  extension_id: string;
  mode: GuardMode;
  blocked_hosts: string[];
}
