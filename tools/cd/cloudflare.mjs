// The Workers API calls continuous delivery makes (tools/cd/deploy.sh), with the token Workers
// Builds gives a build (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID).
//
//   node tools/cd/cloudflare.mjs live <worker>                 # the version serving 100%, and its tag
//   node tools/cd/cloudflare.mjs rollback <worker> <version>   # serve that version again
const ACCOUNT = process.env.CLOUDFLARE_ACCOUNT_ID ?? "0f436d2aabf1f872be90b8dd9d5715e6";
const TOKEN = process.env.CLOUDFLARE_API_TOKEN;

async function api(method, path, body) {
  if (!TOKEN) throw new Error("CLOUDFLARE_API_TOKEN is not set");
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}${path}`, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await response.json();
  if (!json.success) throw new Error(`${method} ${path}: HTTP ${response.status} ${JSON.stringify(json.errors)}`);
  return json.result;
}

const [command, worker, version] = process.argv.slice(2);
if (command === "live") {
  const { deployments } = await api("GET", `/workers/scripts/${worker}/deployments`);
  const latest = deployments.sort((a, b) => b.created_on.localeCompare(a.created_on))[0];
  const whole = latest?.versions.find((v) => v.percentage === 100);
  if (!whole) throw new Error(`${worker} has no version serving all traffic`);
  const detail = await api("GET", `/workers/scripts/${worker}/versions/${whole.version_id}`);
  console.log(JSON.stringify({ deployment: latest.id, version: whole.version_id, tag: detail.annotations?.["workers/tag"] ?? null, created: latest.created_on }));
} else if (command === "rollback") {
  const result = await api("POST", `/workers/scripts/${worker}/deployments`, {
    strategy: "percentage",
    versions: [{ version_id: version, percentage: 100 }],
    annotations: { "workers/message": `rollback by tools/cd to ${version}` },
  });
  console.log(JSON.stringify({ deployment: result.id, version }));
} else {
  console.error("usage: node tools/cd/cloudflare.mjs live <worker> | rollback <worker> <version>");
  process.exit(2);
}
