#!/usr/bin/env node
// dsh-agent-preset-mount-probe.mjs  (cross-platform, SINGLE SOURCE at deploy/shared/)
// End-to-end check that the agent preset a session would use really MOUNTS.
//
// The static checker (dsh-agent-preset-compat-check.mjs) validates row configs;
// this one boots a real dsh app with the same `agent-presets` service the web
// profile ships and calls `agentPresets.standingKeyFor(id)` - the exact call a
// session creation or resume makes - so it reproduces "preset failed to mount"
// without a browser and without a model request.
//
// How: writes a temporary patch overlay that inserts the agent-presets row plus
// a probe plugin, runs `dsh --profile <app> --patch <overlay>`, reads the
// PRESET-PROBE lines, then removes the empty probe session it created (the
// probe exits the process itself, so the app never answers a task).
//
// Usage:
//   node dsh-agent-preset-mount-probe.mjs [--preset <id> ...] [options]
//     --preset <id>    preset to probe (repeatable); default: the
//                      `agent-presets.default` value in <home>/settings.yaml
//     --profile <app>  app profile to boot (default: headless). `headless` is
//                      cheap and catches config failures; a preset that only
//                      resolves in the web host scope may report host failures
//                      there, so re-run with `web` for a faithful scope (boots
//                      the web app on a random port).
//     --home <dir>     harness home (default: $DSH_HOME, else ~/.dsh)
//     --timeout <s>    kill the probe after this many seconds (default 120)
//     --json           machine-readable result
//     --keep-temp      keep the generated overlay directory and print its path
//   DSH_BIN=<path>     dsh executable to run (default: `dsh` on PATH)
//
// Verdicts:
//   OK            the preset mounted; sessions using it can start
//   FAIL(config)  config validation failed ("invalid config") - definitive:
//                 a row schema mismatch is independent of the app that mounts it
//   FAIL(host)    mount failed for another reason; may be an artifact of the
//                 cheap app's host scope - re-run with --profile web
//   INCONCLUSIVE  timeout, no dsh binary, or no probe output (exit 2)
//
// Exit: 0 = every probed preset OK; 1 = at least one FAIL; 2 = inconclusive.

import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'

const USAGE =
  'usage: node dsh-agent-preset-mount-probe.mjs [--preset <id> ...] [--profile <app>] ' +
  '[--home <dir>] [--timeout <s>] [--json] [--keep-temp]'

/** Abort with a usage error (exit 2: nothing was probed). */
function usageError(message) {
  console.error(`dsh-agent-preset-mount-probe: ${message}`)
  console.error(USAGE)
  process.exit(2)
}

const options = {
  profile: 'headless',
  home: process.env.DSH_HOME || join(homedir(), '.dsh'),
  timeout: 120,
  json: false,
  keepTemp: false,
  presets: [],
}
const argv = process.argv.slice(2)
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i]
  const value = argv[i + 1]
  if (arg === '--json') options.json = true
  else if (arg === '--keep-temp') options.keepTemp = true
  else if (arg === '--preset') {
    if (value === undefined || value.startsWith('--')) usageError('missing value for --preset')
    options.presets.push(value)
    i += 1
  } else if (arg === '--profile' || arg === '--home' || arg === '--timeout') {
    if (value === undefined || value.startsWith('--')) usageError(`missing value for ${arg}`)
    if (arg === '--profile') options.profile = value
    else if (arg === '--home') options.home = value
    else {
      const seconds = Number(value)
      if (!Number.isFinite(seconds) || seconds <= 0) usageError(`invalid --timeout: ${value}`)
      options.timeout = seconds
    }
    i += 1
  } else if (arg === '-h' || arg === '--help') {
    console.log(USAGE)
    process.exit(0)
  } else if (arg.startsWith('--')) usageError(`unknown option: ${arg}`)
  else usageError(`unexpected argument: ${arg}`)
}

/** The probe plugin the overlay mounts; it exits the app after reporting. */
const PROBE_PLUGIN = [
  "export const name = 'preset-mount-probe'",
  "export const inject = ['agentPresets']",
  'export function apply(ctx, config) {',
  '  void (async () => {',
  '    for (const id of config.ids ?? []) {',
  '      try {',
  '        const key = await ctx.agentPresets.standingKeyFor(id)',
  "        console.log('PRESET-PROBE OK', id, JSON.stringify(key))",
  '      } catch (error) {',
  "        console.log('PRESET-PROBE FAIL', id, error?.message ?? String(error))",
  '      }',
  '    }',
  '    process.exit(0)',
  '  })()',
  '}',
  '',
].join('\n')

/**
 * The patch overlay: the probe plugin, plus the agent-presets row only when the
 * target app does not ship one (the web profile does; the cheap apps do not,
 * and a duplicate row id fails the whole boot).
 */
function overlaySource(ids, insertAgentPresets) {
  const lines = ['# generated by dsh-agent-preset-mount-probe.mjs - safe to delete', '- insert:']
  if (insertAgentPresets) {
    lines.push(
      '    - id: agent-presets',
      "      name: '@deepseek-ai/dsh-agent-presets'",
      '      config:',
      '        default: standard',
    )
  }
  lines.push('    - id: preset-mount-probe', '      name: ./probe-plugin.mjs', '      config:', '        ids:')
  for (const id of ids) lines.push(`          - ${id}`)
  return `${lines.join('\n')}\n`
}

/** True when the app's composed tree already contains an agent-presets row. */
function appShipsAgentPresets(dshBin, profile) {
  const dump = spawnSync(dshBin, ['--profile', profile, '--dump-config'], {
    encoding: 'utf8',
    timeout: 60 * 1000,
    maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, DSH_HOME: options.home },
    shell: process.platform === 'win32',
  })
  return (dump.stdout ?? '').includes('@deepseek-ai/dsh-agent-presets')
}

/** The app arguments for the profile the probe boots. */
function appArgs(profile) {
  if (profile === 'web') return ['--no-open', '--port', '0']
  return ['noop']
}

/** The `agent-presets.default` value from <home>/settings.yaml, or undefined. */
function settingsDefault() {
  try {
    const mod = createRequire(join(options.home, 'profiles', 'node_modules', 'noop.js'))('yaml')
    const document = mod.parse(readFileSync(join(options.home, 'settings.yaml'), 'utf8'))
    const value = document?.['agent-presets']?.default
    return typeof value === 'string' ? value : undefined
  } catch {
    return undefined
  }
}

/** Parse a PRESET-PROBE line into a verdict, or undefined for other output. */
function parseProbeLine(line) {
  const match = /^PRESET-PROBE (OK|FAIL) (\S+)(?: (.*))?$/.exec(line.trim())
  if (match === null) return undefined
  const [, verdict, id, message] = match
  if (verdict === 'OK') return { id, status: 'OK' }
  const configFailure = (message ?? '').includes('invalid config')
  return { id, status: configFailure ? 'FAIL(config)' : 'FAIL(host)', error: message }
}

/**
 * Remove the empty probe sessions this run created: the booted app creates one
 * session (and mounts its preset) before the probe exits. Only session
 * directories whose name carries this run's unique temp marker are touched.
 * @param marker - unique token embedded in the generated temp directory name.
 * @returns the removed session ids.
 */
function cleanupProbeSessions(marker) {
  const sessionsRoot = join(options.home, 'sessions')
  const removed = []
  try {
    for (const workspace of readdirSync(sessionsRoot)) {
      if (!workspace.includes(marker)) continue
      const workspaceDir = join(sessionsRoot, workspace)
      if (!statSync(workspaceDir).isDirectory()) continue
      removed.push(...readdirSync(workspaceDir))
      rmSync(workspaceDir, { recursive: true, force: true })
    }
  } catch {
    return removed // no session store yet: nothing was created
  }
  if (removed.length > 0) pruneProjections(removed)
  return removed
}

/** Drop the session projections of sessions that no longer exist on disk. */
function pruneProjections(sessionIds) {
  const storages = join(options.home, 'storages')
  const perSession = join(storages, 'session_projcache', 'sessions')
  for (const id of sessionIds) {
    try {
      rmSync(join(perSession, `${id}.json`), { force: true })
    } catch {
      // projection file absent: nothing to prune
    }
  }
  const indexPath = join(storages, 'session_projcache.json')
  try {
    const document = JSON.parse(readFileSync(indexPath, 'utf8'))
    const table = document?.tables?.sessions
    if (table === undefined || table === null || typeof table !== 'object') return
    let changed = false
    for (const id of sessionIds) {
      if (id in table) {
        delete table[id]
        changed = true
      }
    }
    if (changed) writeFileSync(indexPath, `${JSON.stringify(document, null, 2)}\n`)
  } catch {
    // no index file (or unreadable): the per-session files were enough
  }
}

const presets = options.presets.length > 0 ? options.presets : [settingsDefault()].filter((id) => id !== undefined)
if (presets.length === 0) {
  console.log('no preset to probe: no --preset given and settings.yaml sets no agent-presets.default')
  process.exit(0)
}

const dshBin = process.env.DSH_BIN || 'dsh'
const insertAgentPresets = !appShipsAgentPresets(dshBin, options.profile)
const tempDir = mkdtempSync(join(tmpdir(), 'dsh-preset-probe-'))
const marker = basename(tempDir)
writeFileSync(join(tempDir, 'probe-plugin.mjs'), PROBE_PLUGIN)
const overlayPath = join(tempDir, 'probe-overlay.yml')
writeFileSync(overlayPath, overlaySource(presets, insertAgentPresets))

const child = spawnSync(dshBin, ['--profile', options.profile, '--patch', overlayPath, ...appArgs(options.profile)], {
  encoding: 'utf8',
  timeout: options.timeout * 1000,
  maxBuffer: 32 * 1024 * 1024,
  env: { ...process.env, DSH_HOME: options.home },
  shell: process.platform === 'win32',
  // Boot in the generated temp directory: the app derives its session workspace
  // directory from the cwd, so the probe session lands under a workspace whose
  // name carries this run's marker and cleanupProbeSessions can remove it whole.
  cwd: tempDir,
})

const stderrLines = (child.stderr ?? '').split(/\r?\n/).filter((line) => line.trim().length > 0)
const output = `${child.stdout ?? ''}\n${child.stderr ?? ''}`
const outputLines = output.split(/\r?\n/)
const byId = new Map()
for (let i = 0; i < outputLines.length; i += 1) {
  const verdict = parseProbeLine(outputLines[i])
  if (verdict === undefined) continue
  if (verdict.error !== undefined) {
    // Schemastery lists the offending keys on the indented lines that follow.
    for (let j = i + 1; j < outputLines.length && /^\s+\S/.test(outputLines[j]); j += 1) {
      verdict.error += ` ${outputLines[j].trim()}`
      i = j
    }
  }
  byId.set(verdict.id, verdict)
}
const inconclusiveReason =
  child.error !== undefined
    ? `cannot run ${dshBin}: ${child.error.message}`
    : child.signal !== null && child.signal !== undefined
      ? `probe killed (${child.signal}) before it reported`
      : child.status === null
        ? `no probe output within ${options.timeout}s`
        : 'no probe output'
const results = presets.map((id) => byId.get(id) ?? { id, status: 'INCONCLUSIVE', error: inconclusiveReason })
const cleaned = cleanupProbeSessions(marker)
if (options.keepTemp) console.log(`overlay kept at ${tempDir}`)
else rmSync(tempDir, { recursive: true, force: true })

const failing = results.filter((result) => result.status.startsWith('FAIL')).length
const inconclusive = results.filter((result) => result.status === 'INCONCLUSIVE').length
if (options.json) {
  console.log(
    JSON.stringify(
      {
        profile: options.profile,
        presets,
        results,
        failing,
        inconclusive,
        cleanedSessions: cleaned,
        hint: inconclusive > 0 && stderrLines.length > 0 ? stderrLines.slice(-3).join(' | ') : undefined,
      },
      null,
      2,
    ),
  )
} else {
  for (const result of results) {
    if (result.status === 'OK') console.log(`OK            ${result.id}`)
    else if (result.error === undefined) console.log(`${result.status} ${result.id}`)
    else console.log(`${result.status} ${result.id} - ${result.error}`)
  }
  if (results.some((result) => result.status === 'FAIL(host)')) {
    console.log('note: FAIL(host) can be an artifact of the headless host scope; re-run with --profile web')
  }
  if (inconclusive > 0 && stderrLines.length > 0) console.log(`hint: ${stderrLines.slice(-3).join(' | ')}`)
  if (cleaned.length > 0) console.log(`cleaned up ${cleaned.length} probe session(s)`)
  console.log('')
  console.log(`${presets.length} preset(s) probed, ${failing} failing, ${inconclusive} inconclusive`)
}
process.exit(failing > 0 ? 1 : inconclusive > 0 ? 2 : 0)
