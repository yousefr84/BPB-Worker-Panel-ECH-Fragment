#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"

for command in curl node npm; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

read -r -p "Cloudflare ACCOUNT_ID: " ACCOUNT_ID
read -r -p "Existing WORKER_NAME: " WORKER_NAME
read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
printf '\n'

if [[ ! "$ACCOUNT_ID" =~ ^[[:xdigit:]]{32}$ ]]; then
    echo "ACCOUNT_ID must be a 32-character hexadecimal Cloudflare account ID." >&2
    exit 1
fi
ACCOUNT_ID="${ACCOUNT_ID,,}"

if [[ ! "$WORKER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "WORKER_NAME contains unsupported characters." >&2
    exit 1
fi

if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    echo "The Cloudflare API token cannot be empty." >&2
    exit 1
fi

export ACCOUNT_ID WORKER_NAME CLOUDFLARE_API_TOKEN

umask 077
DEPLOY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bpb-custom-worker.XXXXXX")"
export DEPLOY_DIR

cleanup() {
    unset CLOUDFLARE_API_TOKEN
    if [[ -n "${DEPLOY_DIR:-}" && -d "$DEPLOY_DIR" ]]; then
        rm -rf -- "$DEPLOY_DIR"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

readonly SETTINGS_FILE="$DEPLOY_DIR/settings.json"
readonly DEPLOYMENTS_FILE="$DEPLOY_DIR/deployments.json"
readonly CURRENT_WORKER_FILE="$DEPLOY_DIR/current-worker.js"
readonly EMBEDDED_SETTINGS_FILE="$DEPLOY_DIR/embedded-settings.json"
readonly DEPLOY_WORKER_FILE="$DEPLOY_DIR/worker.js"
readonly UPLOAD_METADATA_FILE="$DEPLOY_DIR/upload-metadata.json"
readonly UPLOAD_RESULT_FILE="$DEPLOY_DIR/upload-result.json"

export SETTINGS_FILE DEPLOYMENTS_FILE CURRENT_WORKER_FILE
export EMBEDDED_SETTINGS_FILE DEPLOY_WORKER_FILE UPLOAD_METADATA_FILE
export UPLOAD_RESULT_FILE

auth_header="Authorization: Bearer $CLOUDFLARE_API_TOKEN"
worker_api="$CF_API_BASE/accounts/$ACCOUNT_ID/workers/scripts/$WORKER_NAME"

echo "Checking the existing Worker and its bindings..."
curl --fail-with-body --silent --show-error \
    "$worker_api/settings" \
    -H "$auth_header" \
    -o "$SETTINGS_FILE"

node <<'NODE'
const fs = require('node:fs');

const response = JSON.parse(fs.readFileSync(process.env.SETTINGS_FILE, 'utf8'));
if (!response.success || !response.result) {
    throw new Error(`Unable to read existing Worker settings: ${JSON.stringify(response.errors || [])}`);
}

const kvBinding = (response.result.bindings || []).find(
    binding => binding.name === 'kv' && binding.type === 'kv_namespace'
);

if (!kvBinding?.namespace_id) {
    throw new Error('Refusing to continue: existing kv namespace binding was not found.');
}

if (!response.result.compatibility_date) {
    throw new Error('Refusing to continue: existing compatibility date was not returned.');
}

console.log(`Existing kv binding confirmed: ${kvBinding.namespace_id}`);
NODE

echo "Recording the active production version for strict binding inheritance..."
curl --fail-with-body --silent --show-error \
    "$worker_api/deployments" \
    -H "$auth_header" \
    -o "$DEPLOYMENTS_FILE"

OLD_VERSION_ID="$(node <<'NODE'
const fs = require('node:fs');

const response = JSON.parse(fs.readFileSync(process.env.DEPLOYMENTS_FILE, 'utf8'));
const deployment = response.result?.deployments?.[0];
const versions = deployment?.versions || [];
const active = versions.filter(version => version.percentage === 100);

if (!response.success || active.length !== 1 || !active[0].version_id) {
    throw new Error('Expected exactly one active production version at 100% traffic.');
}

process.stdout.write(active[0].version_id);
NODE
)"
export OLD_VERSION_ID

echo "Downloading the existing Worker without changing it..."
node <<'NODE'
const fs = require('node:fs');

(async () => {
    const url = `https://api.cloudflare.com/client/v4/accounts/${process.env.ACCOUNT_ID}`
        + `/workers/scripts/${process.env.WORKER_NAME}/content/v2`;
    const response = await fetch(url, {
        headers: { Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` }
    });

    if (!response.ok) {
        throw new Error(`Worker download failed with HTTP ${response.status}: ${await response.text()}`);
    }

    const contentType = response.headers.get('content-type') || '';
    let source;

    if (contentType.includes('multipart/form-data')) {
        const form = await response.formData();
        let moduleName = response.headers.get('cf-worker-main-module-part');
        const metadataPart = form.get('metadata');

        if (!moduleName && metadataPart) {
            const metadataText = typeof metadataPart === 'string'
                ? metadataPart
                : await metadataPart.text();
            moduleName = JSON.parse(metadataText).main_module;
        }

        let modulePart = moduleName ? form.get(moduleName) : null;
        if (!modulePart) {
            modulePart = [...form.entries()]
                .find(([name, value]) => (
                    name !== 'metadata'
                    && value
                    && typeof value.text === 'function'
                ))?.[1];
        }

        if (!modulePart) throw new Error('The existing Worker main module was not found.');
        source = typeof modulePart === 'string' ? modulePart : await modulePart.text();
    } else {
        source = await response.text();
    }

    if (!source.trim()) throw new Error('The downloaded Worker source is empty.');
    fs.writeFileSync(process.env.CURRENT_WORKER_FILE, source, { mode: 0o600 });
})().catch(error => {
    console.error(error.message);
    process.exit(1);
});
NODE

echo "Extracting the existing embedded BPB settings..."
node <<'NODE'
const fs = require('node:fs');

const source = fs.readFileSync(process.env.CURRENT_WORKER_FILE, 'utf8');
const patterns = [
    /const\s+EMBEDED_SETTINGS\s*=\s*/g,
    /["']EMBEDED_SETTINGS["']\s*:\s*/g
];

function readJsonObject(start) {
    const open = source.indexOf('{', start);
    if (open < 0) return undefined;

    let depth = 0;
    let quoted = false;
    let escaped = false;

    for (let index = open; index < source.length; index++) {
        const char = source[index];

        if (quoted) {
            if (escaped) escaped = false;
            else if (char === '\\') escaped = true;
            else if (char === '"') quoted = false;
            continue;
        }

        if (char === '"') {
            quoted = true;
        } else if (char === '{') {
            depth++;
        } else if (char === '}') {
            depth--;
            if (depth === 0) {
                const candidate = source.slice(open, index + 1);
                try {
                    return JSON.parse(candidate);
                } catch {
                    return undefined;
                }
            }
        }
    }

    return undefined;
}

let settings;
for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) {
        const candidate = readJsonObject(match.index + match[0].length);
        if (
            candidate?.accID
            && candidate?.accEmail
            && candidate?.apiToken
            && candidate?.vlUUID
            && candidate?.trPass
            && candidate?.securePath
            && candidate?.mainDomain
        ) {
            settings = candidate;
            break;
        }
    }
    if (settings) break;
}

if (!settings) {
    throw new Error('Could not safely extract EMBEDED_SETTINGS from the existing Worker.');
}

if (settings.accID !== process.env.ACCOUNT_ID) {
    throw new Error('Embedded account ID does not match the requested Cloudflare account.');
}

if (settings.mainDomain.split('.')[0] !== process.env.WORKER_NAME) {
    throw new Error('Embedded main domain does not match the requested Worker name.');
}

fs.writeFileSync(
    process.env.EMBEDDED_SETTINGS_FILE,
    JSON.stringify(settings),
    { mode: 0o600 }
);
NODE

echo "Running TypeScript checks and the production build..."
cd "$REPO_ROOT"
npm run check
npm run build

if [[ ! -s "$REPO_ROOT/dist/worker.js" ]]; then
    echo "Build did not produce dist/worker.js." >&2
    exit 1
fi

echo "Combining the existing embedded settings with the modified build..."
node <<'NODE'
const fs = require('node:fs');

const settingsText = fs.readFileSync(process.env.EMBEDDED_SETTINGS_FILE, 'utf8');
const settings = JSON.parse(settingsText);
const build = fs.readFileSync('dist/worker.js', 'utf8');

if (!build.trim()) throw new Error('dist/worker.js is empty.');

const source = `const EMBEDED_SETTINGS = ${JSON.stringify(settings)};\n${build}`;
fs.writeFileSync(process.env.DEPLOY_WORKER_FILE, source, { mode: 0o600 });
NODE

echo "Preparing strict inheritance metadata for all existing bindings..."
node <<'NODE'
const fs = require('node:fs');

const response = JSON.parse(fs.readFileSync(process.env.SETTINGS_FILE, 'utf8'));
const settings = response.result;
const bindings = (settings.bindings || [])
    .filter(binding => binding.name)
    .map(binding => ({
        type: 'inherit',
        name: binding.name,
        version_id: process.env.OLD_VERSION_ID
    }));

if (!bindings.some(binding => binding.name === 'kv')) {
    throw new Error('Refusing to upload: the kv binding is not present in inheritance metadata.');
}

const metadata = {
    main_module: 'worker.js',
    bindings,
    compatibility_date: settings.compatibility_date,
    compatibility_flags: settings.compatibility_flags || [],
    annotations: {
        'workers/message': 'BPB Raw ECH Fragment custom build'
    }
};

fs.writeFileSync(
    process.env.UPLOAD_METADATA_FILE,
    JSON.stringify(metadata),
    { mode: 0o600 }
);
NODE

echo "Uploading a new inactive version to the existing Worker..."
curl --fail-with-body --silent --show-error \
    -X POST \
    "$worker_api/versions?bindings_inherit=strict" \
    -H "$auth_header" \
    -F "metadata=<$UPLOAD_METADATA_FILE;type=application/json" \
    -F "worker.js=@$DEPLOY_WORKER_FILE;type=application/javascript+module" \
    -o "$UPLOAD_RESULT_FILE"

NEW_VERSION_ID="$(node <<'NODE'
const fs = require('node:fs');

const response = JSON.parse(fs.readFileSync(process.env.UPLOAD_RESULT_FILE, 'utf8'));
if (!response.success || !response.result?.id) {
    throw new Error(`Version upload failed: ${JSON.stringify(response.errors || [])}`);
}

process.stdout.write(response.result.id);
NODE
)"

echo
echo "Inactive Worker version uploaded successfully."
echo "NEW_VERSION_ID=$NEW_VERSION_ID"
echo
echo "Production was not changed. To promote this version manually, run:"
echo
cat <<EOF
read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN; echo
curl --fail-with-body --silent --show-error \\
  -X POST \\
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/scripts/$WORKER_NAME/deployments" \\
  -H "Authorization: Bearer \$CLOUDFLARE_API_TOKEN" \\
  -H "Content-Type: application/json" \\
  --data '{"strategy":"percentage","versions":[{"version_id":"$NEW_VERSION_ID","percentage":100}],"annotations":{"workers/message":"Deploy BPB Raw ECH Fragment custom build"}}'
unset CLOUDFLARE_API_TOKEN
EOF
