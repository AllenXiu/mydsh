#!/usr/bin/env node
// dsh-web-plugin-compat-check.mjs  (cross-platform, SINGLE SOURCE at deploy/shared/)
// Pre-flight: check every third-party plugin in the web profile against a
// TARGET dsh host version and report which ones would conflict.
//
// Signals examined per plugin (any may be absent):
//   1. pkg.dsh.engines.dsh            - semver range the plugin needs from dsh
//   2. pkg.dsh.compatibility.dshReleases - { "<dsh-version>": "compatible"|... }
//   3. peerDependencies["@deepseek-ai/dsh-*"] - semver ranges vs host subpackages
//
// Usage:
//   node dsh-web-plugin-compat-check.mjs [--profile <dir>] [--host <version>] [--conflict-names]
//   --host defaults to the installed host version; pass the prospective NEW
//   version to preview conflicts AFTER an upgrade.
//   --conflict-names: print only the bare package names of CONFLICT plugins
//   (one per line) instead of the human report.
//
// Cross-platform: locates the dsh install via `npm prefix -g` (win32) or the
// resolved dsh bin (macOS/Linux), and loads semver from the dsh installation's
// own node_modules.
// Exit 0 always (report text is the output); the caller renders it.

import { readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'

const require = createRequire(import.meta.url)

const args = process.argv.slice(2)
const argVal = (flag) => {
  const i = args.indexOf(flag)
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined
}

const profileDir = argVal('--profile') || join(homedir(), '.dsh/profiles/web')
const host = argVal('--host') || argVal('--target')
const conflictNamesOnly = args.includes('--conflict-names')

// --- locate the dsh install (cross-platform) ---
function dshRoot() {
  try {
    if (process.platform === 'win32') {
      const prefix = execSync('npm prefix -g', { encoding: 'utf8', shell: process.env.ComSpec || 'cmd.exe' }).trim()
      const p = join(prefix, 'node_modules', '@deepseek-ai', 'dsh')
      if (existsSync(join(p, 'package.json'))) return p
    } else {
      const bin = execSync('command -v dsh', { encoding: 'utf8' }).trim()
      const real = execSync(`readlink -f "${bin}"`, { encoding: 'utf8' }).trim()
      const libIndex = real.indexOf('lib/node_modules')
      if (libIndex !== -1) {
        return real.slice(0, libIndex + 'lib/node_modules'.length) + '/@deepseek-ai/dsh'
      }
    }
  } catch { /* fall through */ }
  return undefined
}
const DSH_ROOT = dshRoot()
const HOST_DEP_ROOT = DSH_ROOT ? join(DSH_ROOT, 'node_modules') : undefined

// --- load semver from the dsh install's dependency tree ---
function loadSemver() {
  if (!DSH_ROOT) return undefined
  const cands = [
    join(DSH_ROOT, 'node_modules', 'semver'),
    join(DSH_ROOT, '..', 'node_modules', 'semver'),
    join(homedir(), 'AppData', 'Roaming', 'npm', 'node_modules', 'semver'),
  ]
  for (const c of cands) {
    try {
      if (existsSync(join(c, 'package.json'))) return require(c)
    } catch { /* next */ }
  }
  try { return require('semver') } catch { return undefined }
}
const semver = loadSemver()

function readJson(p) {
  try {
    return JSON.parse(readFileSync(p, 'utf8'))
  } catch {
    return undefined
  }
}

// --- host version under test ---
let hostVersion = host
let hostSubversionForTarget = undefined
if (hostVersion) {
  hostSubversionForTarget = () => hostVersion
} else {
  const dshPkg = DSH_ROOT ? readJson(join(DSH_ROOT, 'package.json')) : undefined
  hostVersion = dshPkg?.version || 'unknown'
}

const hostSubversionCache = new Map()
function hostSubversion(name) {
  if (hostSubversionForTarget) return hostSubversionForTarget()
  const bare = name.startsWith('@deepseek-ai/') ? name.slice('@deepseek-ai/'.length) : name
  if (!hostSubversionCache.has(bare)) {
    const p = readJson(join(HOST_DEP_ROOT, '@deepseek-ai', bare, 'package.json'))
    hostSubversionCache.set(bare, p?.version)
  }
  return hostSubversionCache.get(bare)
}
const satisfies = (range, version) => {
  if (!semver || !range || !version) return undefined
  try {
    return semver.satisfies(version, range, { includePrerelease: true })
  } catch {
    return undefined
  }
}

// --- which profile deps are third-party plugins (not @deepseek-ai scope) ---
const profile = readJson(join(profileDir, 'package.json'))
const bundles = profile?.dsh?.profile?.bundles ?? []
const depNames = Object.keys(profile?.dependencies ?? {})
const thirdParty = depNames.filter(
  (n) => !n.startsWith('@deepseek-ai/') && bundles.includes(n),
)

const lines = []
// Host on the 0.1.2 line? (prerelease-agnostic: "0.1.2-rc.1", "0.1.2-alpha.x", ...)
const hostIs012 = /^0\.1\.2/.test(hostVersion)
for (const name of thirdParty) {
  const pkg = readJson(join(profileDir, 'node_modules', name, 'package.json'))
  if (!pkg) {
    lines.push(`  ? ${name}  (not installed; cannot check)`)
    continue
  }
  const version = pkg.version ?? '?'

  const dshEngineRange = pkg.dsh?.engines?.dsh
  const releases = pkg.dsh?.compatibility?.dshReleases
  let releaseState
  let releaseDeclared = false
  if (releases && typeof releases === 'object') {
    releaseDeclared = true
    releaseState = Object.prototype.hasOwnProperty.call(releases, hostVersion)
      ? releases[hostVersion]
      : undefined
  }

  const peerDeps = pkg.peerDependencies ?? {}
  const hostPeerEntries = Object.entries(peerDeps).filter(([k]) => k.startsWith('@deepseek-ai/'))
  const peerIssues = []
  for (const [dep, range] of hostPeerEntries) {
    if (dep === '@deepseek-ai/cordis' || dep === '@deepseek-ai/schemastery') continue
    const installed = hostSubversion(dep)
    const ok = installed ? satisfies(range, installed) : undefined
    if (ok === false) {
      peerIssues.push(`${dep} wants ${range}, host has ${installed}`)
    }
  }

  // --- verdict ---
  const problems = []
  if (dshEngineRange && satisfies(dshEngineRange, hostVersion) === false) {
    problems.push(`engines.dsh requires ${dshEngineRange}`)
  }
  if (releaseDeclared && releaseState !== 'compatible') {
    problems.push(`compatibility list does not cover dsh ${hostVersion}`)
  }
  problems.push(...peerIssues)

  // Known transitive/runtime conflicts that package manifests cannot express.
  // Empirically: @linxin666/dsh-web-all < 0.3.9 pins dsh-better-sidebar 0.15.x,
  // whose server half imports `settingsNamespace` from @deepseek-ai/dsh-settings
  // - an export removed in dsh 0.1.2. So web-all < 0.3.9 crashes on a 0.1.2+
  // host even though its engines claim >=0.1.1-rc.1.
  if (hostIs012 && name === '@linxin666/dsh-web-all' && version && semver && semver.lt(version, '0.3.9')) {
    problems.push('known: web-all <0.3.9 pins better-sidebar 0.15.x which needs settingsNamespace removed in dsh 0.1.2+')
  }

  if (problems.length > 0) {
    lines.push(`  !! ${name}@${version}  CONFLICT on dsh ${hostVersion}: ${problems.join('; ')}`)
  } else if (dshEngineRange || releaseState === 'compatible' || hostPeerEntries.length > 0) {
    lines.push(`  ok ${name}@${version}  compatible with dsh ${hostVersion}`)
  } else {
    lines.push(`  -- ${name}@${version}  no host-version declaration (low risk, unverified)`)
  }
}

if (thirdParty.length === 0) lines.push('  (no third-party plugins installed)')

// --conflict-names delegates name extraction to this one file, so the macOS
// (bash) and Windows (PowerShell) flows do not re-implement the same regex.
if (conflictNamesOnly) {
  const names = []
  for (const line of lines) {
    const m = line.match(/^  !! (@[a-z0-9._-]+\/[a-z0-9._-]+|[a-z0-9][a-z0-9._-]*)@[0-9][^ ]*/)
    if (m) names.push(m[1])
  }
  console.log(names.join('\n'))
} else {
  console.log(lines.join('\n'))
}

