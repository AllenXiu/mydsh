#!/usr/bin/env node
// dsh-web-plugin-compat-check.mjs
// Pre-flight: check every third-party plugin in the web profile against a
// TARGET dsh host version and report which ones would conflict.
//
// Signals examined per plugin (any may be absent):
//   1. pkg.dsh.engines.dsh            - semver range the plugin needs from dsh
//   2. pkg.dsh.compatibility.dshReleases - { "<dsh-version>": "compatible"|... }
//   3. peerDependencies["@deepseek-ai/dsh-*"] - semver ranges vs host subpackages
//
// Usage:
//   node dsh-web-plugin-compat-check.mjs [--profile <dir>] [--target <version>]
//   --target defaults to the installed host version; pass the prospective NEW
//   version (e.g. the value the confirm dialog is about to install) to preview
//   conflicts AFTER an upgrade.
//
// Exit 0 always (report text is the output); the caller renders it.

import { createRequire } from 'node:module'
import { readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'

const require = createRequire(import.meta.url)

const args = process.argv.slice(2)
const argVal = (flag) => {
  const i = args.indexOf(flag)
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined
}

const profileDir = argVal('--profile') || join(homedir(), '.dsh/profiles/web')
const host = argVal('--host')

// --- locate semver from the host installation (dsh ships semver) ---
import { execSync } from 'node:child_process'
function dshRoot() {
  // Resolve the real global dsh install (nvm's bin/dsh -> .../node_modules/@deepseek-ai/dsh)
  try {
    const bin = execSync('command -v dsh', { encoding: 'utf8' }).trim()
    const real = execSync(`readlink -f "${bin}"`, { encoding: 'utf8' }).trim()
    // .../versions/node/v22.23.2/bin/dsh -> .../lib/node_modules/@deepseek-ai/dsh/bin.js
    const libIndex = real.indexOf('lib/node_modules')
    if (libIndex !== -1) {
      return real.slice(0, libIndex + 'lib/node_modules'.length) + '/@deepseek-ai/dsh'
    }
  } catch { /* fall through */ }
  return undefined
}
const DSH_ROOT = dshRoot()
const HOST_DEP_ROOT = DSH_ROOT ? join(DSH_ROOT, 'node_modules') : undefined
function loadSemver() {
  if (!HOST_DEP_ROOT) return undefined
  try {
    return require(join(HOST_DEP_ROOT, 'semver'))
  } catch {
    return undefined
  }
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
  // Simulating an upgrade: dsh publishes its @deepseek-ai/dsh-* subpackages in
  // lockstep with the main package version, so peerDep checks against the
  // target use the target version for every subpackage.
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


// --- which profile deps are third-party plugins (not @deepseek-ai scope) ---
const profile = readJson(join(profileDir, 'package.json'))
const bundles = profile?.dsh?.profile?.bundles ?? []
const depNames = Object.keys(profile?.dependencies ?? {})
const thirdParty = depNames.filter(
  (n) => !n.startsWith('@deepseek-ai/') && bundles.includes(n),
)

const satisfies = (range, version) => {
  if (!semver || !range || !version) return undefined
  try {
    // prerelease handling: 0.1.2-rc.1 must be allowed to match ^0.1.2-alpha.2
    return semver.satisfies(version, range, { includePrerelease: true })
  } catch {
    return undefined
  }
}

const lines = []
for (const name of thirdParty) {
  const pkg = readJson(join(profileDir, 'node_modules', name, 'package.json'))
  if (!pkg) {
    lines.push(`  ? ${name}  (not installed; cannot check)`)
    continue
  }
  const version = pkg.version ?? '?'

  // signal 1: dsh.engines.dsh
  const dshEngineRange = pkg.dsh?.engines?.dsh

  // signal 2: dsh.compatibility.dshReleases
  const releases = pkg.dsh?.compatibility?.dshReleases
  let releaseState
  if (releases && typeof releases === 'object') {
    releaseState = Object.prototype.hasOwnProperty.call(releases, hostVersion)
      ? releases[hostVersion]
      : undefined
  }

  // signal 3: @deepseek-ai peerDeps
  const peerDeps = pkg.peerDependencies ?? {}
  const hostPeerEntries = Object.entries(peerDeps).filter(([k]) => k.startsWith('@deepseek-ai/'))
  const peerIssues = []
  for (const [dep, range] of hostPeerEntries) {
    if (dep === '@deepseek-ai/cordis' || dep === '@deepseek-ai/schemastery') continue // infra
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
  if (releaseState !== undefined && releaseState !== 'compatible') {
    problems.push(`compatibility marks ${hostVersion} as "${releaseState}"`)
  }
  problems.push(...peerIssues)

  if (problems.length > 0) {
    lines.push(`  !! ${name}@${version}  CONFLICT on dsh ${hostVersion}: ${problems.join('; ')}`)
  } else if (dshEngineRange || releaseState !== undefined || hostPeerEntries.length > 0) {
    lines.push(`  ok ${name}@${version}  compatible with dsh ${hostVersion}`)
  } else {
    lines.push(`  -- ${name}@${version}  no host-version declaration (low risk, unverified)`)
  }
}

if (thirdParty.length === 0) lines.push('  (no third-party plugins installed)')
console.log(lines.join('\n'))
