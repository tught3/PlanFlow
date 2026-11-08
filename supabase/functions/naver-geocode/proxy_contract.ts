export type ProxyContract =
  | { kind: "geocode"; query: string }
  | { kind: "directions"; start: string; goal: string; option: "trafast" }
  | { kind: "unsupported_mode" }
  | { kind: "invalid"; error: string };

function coordinatePair(value: string | null): boolean {
  if (!value) return false;
  const parts = value.split(",");
  if (parts.length !== 2 || parts.some((part) => part.trim() === "")) return false;
  const [lng, lat] = parts.map(Number);
  return Number.isFinite(lng) && Number.isFinite(lat) &&
    lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90;
}

export function parseProxyContract(params: URLSearchParams): ProxyContract {
  const keys = [...params.keys()];
  if (keys.length === 1 && keys[0] === "query") {
    return { kind: "geocode", query: params.get("query")?.trim() ?? "" };
  }
  if (params.has("mode")) {
    if (params.get("mode") === "transit") return { kind: "unsupported_mode" };
    if (params.get("mode") !== "car" || keys.some((key) => !["mode", "start", "goal", "option"].includes(key)) ||
      keys.length !== 4 || params.get("option") !== "trafast" ||
      !coordinatePair(params.get("start")) || !coordinatePair(params.get("goal"))) {
      return { kind: "invalid", error: "Invalid directions parameters." };
    }
    return { kind: "directions", start: params.get("start")!, goal: params.get("goal")!, option: "trafast" };
  }
  if (keys.length === 0) return { kind: "geocode", query: "" };
  return { kind: "invalid", error: "Invalid geocode parameters." };
}
