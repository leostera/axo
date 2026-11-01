import { FakeOAuth, json } from "./fake-oauth";

/**
 * Withings as the Withings app sees it: a token endpoint that is an API action
 * (`action=requesttoken`), no PKCE, commas between scopes, rotating refresh tokens, and every
 * answer HTTP 200 as `{ status, body }`, status 401 for a token it does not take. Measures,
 * activity, sleep, ECGs and devices, each a form POST with an `action`.
 */
export class FakeWithings {
  readonly oauth = new FakeOAuth({ authorizeUrl: "https://account.withings.com/oauth2_user/authorize2", tokenAuth: "body", pkce: false, scopeSeparator: ",", rotates: true, answerSeparator: "," });
  readonly calls: Array<{ as: string; path: string; form: URLSearchParams }> = [];
  /** The user ID Withings gives each person. */
  readonly userIds = new Map([["ada", 31_337_001], ["grace", 31_337_002]]);

  constructor() {
    this.oauth.tokenLifetime = 10_800;
  }

  async handle(request: Request): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (url.origin !== "https://wbsapi.withings.net") return undefined;
    if (request.method !== "POST") return json({ status: 2555, error: "An unknown error occurred" });
    const form = new URLSearchParams(await request.text());
    if (url.pathname === "/v2/oauth2") {
      if (form.get("action") !== "requesttoken") return json({ status: 293, error: "Invalid action" });
      const result = this.oauth.token(form, request.headers);
      if (!result.ok) return json({ status: result.error === "invalid_client" ? 503 : 601, error: result.error });
      return json({ status: 0, body: { userid: this.userIds.get(result.person), access_token: result.accessToken, refresh_token: result.refreshToken, expires_in: result.expiresIn, scope: result.scope, token_type: "Bearer" } });
    }
    const as = this.oauth.who(request);
    if (!as) return json({ status: 401, error: "XRequestID: Not provided invalid_token: The access token provided is invalid" });
    this.calls.push({ as, path: url.pathname, form });
    const call = `${url.pathname} ${form.get("action")}`;
    switch (call) {
      case "/measure getmeas":
        return json({ status: 0, body: { updatetime: 1, timezone: "Europe/London", more: 0, offset: 0, measuregrps: [
          { grpid: 1, attrib: 0, date: 1_793_000_000, category: 1, deviceid: "scale1", measures: [{ value: 72350, type: 1, unit: -3 }, { value: 215, type: 6, unit: -1 }] },
          { grpid: 2, attrib: 0, date: 1_792_900_000, category: 1, deviceid: "bpm1", measures: [{ value: 121, type: 10, unit: 0 }, { value: 79, type: 9, unit: 0 }, { value: 64, type: 11, unit: 0 }] },
        ] } });
      case "/v2/measure getactivity":
        return json({ status: 0, body: { more: false, offset: 0, activities: [{ date: "2026-10-30", timezone: "Europe/London", steps: 9120, distance: 6800.5, elevation: 12, soft: 3600, moderate: 1200, intense: 300, active: 1500, calories: 420.5, totalcalories: 2310, hr_average: 71 }] } });
      case "/v2/sleep getsummary":
        return json({ status: 0, body: { more: false, offset: 0, series: [{ date: "2026-10-31", startdate: 1_793_000_000, enddate: 1_793_028_800, data: { total_sleep_time: 26_000, deepsleepduration: 5000, sleep_score: 81 } }] } });
      case "/v2/heart list":
        return json({ status: 0, body: { more: false, offset: 0, series: [{ deviceid: "watch1", timestamp: 1_793_000_000, ecg: { signalid: 77, afib: 0 }, heart_rate: 62 }] } });
      case "/v2/user getdevice":
        return json({ status: 0, body: { devices: [{ deviceid: "scale1", type: "Scale", model: "Body+", battery: "high", last_session_date: 1_793_000_000, timezone: "Europe/London" }] } });
      default:
        return json({ status: 2555, error: "An unknown error occurred" });
    }
  }
}
