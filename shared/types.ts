export type GuardMode = "idle" | "active";

export type ScanAction = "allow" | "block" | "redact";

export interface ScanRequest {
  text: string;
}

export interface ScanResponse {
  action: ScanAction;
  redacted_text: string;
  reason: string;
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
