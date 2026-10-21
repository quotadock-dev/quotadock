import { access, realpath, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const help = `Usage: node bridge/service.mjs launchd|systemd --codexbar /absolute/path/to/codexbar
       node bridge/service.mjs --help
Print only a macOS LaunchAgent plist or Linux systemd USER unit to stdout.
Never installs, enables, starts, pairs, or reads private collector state.
Run as your normal user, never root; use only your own user service manager.
Requires prior cloud.mjs pairing, complete account mappings, and a working
CodexBar executable. Rendering does not check readiness or credentials.
Your user computer must remain online and awake; user-session availability
and service-manager environment still matter. No automatic restart on exit:
the collector retries transient failures internally; repair fatal errors manually.
Paths are pinned to this checkout and the running Node executable; regenerate
after moving the checkout or replacing Node/CodexBar. No caller environment is exported.
`;

function safePath(value) {
  // Refuse normalization surprises, line injection, invalid XML and invisible
  // formatting characters rather than silently changing an executable's name.
  if (typeof value !== 'string' || !isAbsolute(value) || normalize(value) !== value ||
      /[\p{Cc}\p{Cf}\p{Cs}\uFFFE\uFFFF]/u.test(value)) throw Error('path');
  return value;
}

async function pinned(value, executable = false) {
  safePath(value);
  const resolved = safePath(await realpath(value));
  if (!(await stat(resolved)).isFile()) throw Error('path');
  await access(resolved, executable ? constants.R_OK | constants.X_OK : constants.R_OK);
  return resolved;
}

const xml = value => value.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);
// Escape unit/word syntax and percent specifiers. ExecStart's ':' prefix disables
// dollar environment expansion entirely, including literal '$HOME' path names.
const unit = value => `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/%/g, '%%')}"`;

async function main() {
  const args = process.argv.slice(2);
  if (!args.length || (args.length === 1 && ['--help', 'help'].includes(args[0]))) {
    process.stdout.write(help); return;
  }
  if (args.length !== 3 || !['launchd', 'systemd'].includes(args[0]) || args[1] !== '--codexbar') throw Error('usage');
  if (!['darwin', 'linux'].includes(process.platform) || typeof process.getuid !== 'function' || process.getuid() === 0) throw Error('user');
  const node = await pinned(process.execPath, true);
  const cloud = await pinned(fileURLToPath(new URL('./cloud.mjs', import.meta.url)));
  const binary = await pinned(args[2], true);
  const home = safePath(homedir());
  const cwd = safePath(dirname(dirname(cloud)));
  // Fixed non-secret environment; do not copy the invoking process environment.
  const env = { HOME: home, PATH: [dirname(binary), dirname(node), '/usr/local/bin', '/usr/bin', '/bin'].join(':'), QUOTADOCK_CODEXBAR_BIN: binary, NODE_OPTIONS: '', NODE_PATH: '' };
  // A colon in a PATH directory changes its meaning. Do not accept that ambiguity.
  if ([dirname(binary), dirname(node)].some(p => p.includes(':'))) throw Error('path');
  if (args[0] === 'launchd') {
    process.stdout.write(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.quotadock.collector</string>
  <key>ProgramArguments</key><array>${[node, cloud, 'run'].map(v => `<string>${xml(v)}</string>`).join('')}</array>
  <key>WorkingDirectory</key><string>${xml(cwd)}</string>
  <key>EnvironmentVariables</key><dict>${Object.entries(env).map(([k, v]) => `<key>${k}</key><string>${xml(v)}</string>`).join('')}</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
`);
  } else {
    process.stdout.write(`[Unit]
Description=QuotaDock paired local collector (user service)

[Service]
Type=simple
ExecStart=:${[node, cloud, 'run'].map(unit).join(' ')}
${Object.entries(env).map(([k, v]) => `Environment=${unit(`${k}=${v}`)}`).join('\n')}
Restart=no
UMask=0077

[Install]
WantedBy=default.target
`);
  }
}

main().catch(() => {
  // Do not echo arguments, environment values, OS errors or private filenames.
  process.stderr.write('QuotaDock service: invalid command, unsafe/inaccessible path, or unsupported/root user. See --help.\n');
  process.exitCode = 1;
});
