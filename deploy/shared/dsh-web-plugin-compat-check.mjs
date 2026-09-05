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
//   --conflict-names: package names of REJECT (!! CONFLICT) plugins, one per line
//   --warn-names    : package names of WARN (??) plugins, one per line
//   --verdict-names : "<VERDICT>\t<name>" per REJECT/WARN plugin (TSV, for scripts)
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
const warnNamesOnly = args.includes('--warn-names')
const verdictNames = args.includes('--verdict-names')

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
// The smoke probe resolves against the INSTALLED host; it is decisive only
// when the version under test equals that install (no --host, or --host is the
// running version). For a future target it stays advisory.
let installedHostVersion = undefined
if (hostVersion) {
  hostSubversionForTarget = () => hostVersion
} else {
  const dshPkg = DSH_ROOT ? readJson(join(DSH_ROOT, 'package.json')) : undefined
  hostVersion = dshPkg?.version || 'unknown'
}
{
  const dshPkg = DSH_ROOT ? readJson(join(DSH_ROOT, 'package.json')) : undefined
  installedHostVersion = dshPkg?.version
}
const probeApplies = host === undefined || host === installedHostVersion

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

// --- smoke probe: does the ACTUAL host export the @deepseek-ai/* subpaths a
// plugin imports? Catches manifest lies (peerDeps "*", stale engines) because
// it inspects the real export map of the host the plugin would run against. ---
function hostProvides(specifier) {
  // specifier like "@deepseek-ai/dsh-client-runtime/client" or "@deepseek-ai/cordis"
  if (!specifier.startsWith('@deepseek-ai/')) return undefined // not host-scoped
  const rest = specifier.slice('@deepseek-ai/'.length)
  const slash = rest.indexOf('/')
  const bare = slash === -1 ? rest : rest.slice(0, slash)
  const sub = slash === -1 ? '' : rest.slice(slash) // "/client"
  const pkgDir = HOST_DEP_ROOT ? join(HOST_DEP_ROOT, '@deepseek-ai', bare) : undefined
  if (!pkgDir) return undefined
  const pj = readJson(join(pkgDir, 'package.json'))
  if (!pj) return false // subpackage not present in this host
  if (!sub) return true
  const ex = pj.exports
  const want = './' + sub.slice(1)
  if (ex && typeof ex === 'object') {
    if (ex[want]) return true
    if (ex['./*']) return true
    return false // host uses an exports map and this subpath is absent
  }
  // no exports map: fall back to physical file
  const cands = [join(pkgDir, sub.slice(1)), join(pkgDir, sub.slice(1) + '.js'), join(pkgDir, sub.slice(1) + '.mjs')]
  return cands.some((c) => existsSync(c))
}

// Extract every @deepseek-ai/* specifier the plugin actually imports in its
// entry artifacts. Bundles keep externals as string literals; minifiers alias
// require to a short local (e.g. `e("@deepseek-ai/x")`), so match ANY
// identifier call whose sole string argument starts with @deepseek-ai/, plus
// the `from "..."` / `import "..."` ESM forms.
const IMPORT_RE = /\b(?:[A-Za-z_$][\w$]*)\s*\(\s*["'`](@deepseek-ai\/[^"'`]+)["'`]\s*\)|(?:from|import)\s+["'`](@deepseek-ai\/[^"'`]+)["'`]/g

// Collect the resolved entry files for one role. Server entries live under
// "." or "./host" and resolve through node's exports map; client bundles live
// under "./client" and resolve through the browser module table instead, where
// bare @deepseek-ai/dsh-client-* names are table entries, not node packages.
function entryFiles(pkg, pkgJson, role) {
  const files = []
  const ex = pkgJson.exports
  const key = role === 'client' ? './client' : '.'
  if (ex && typeof ex === 'object') {
    const v = ex[key] || (role === 'server' ? ex['./host'] : undefined)
    if (typeof v === 'string') files.push(join(pkg, v))
    else if (v && typeof v === 'object' && typeof v.default === 'string') files.push(join(pkg, v.default))
  }
  if (role === 'server' && files.length === 0 && pkgJson.main) files.push(join(pkg, pkgJson.main))
  if (files.length === 0 && role === 'client') files.push(join(pkg, 'client.js'))
  return files
}

// True conflict when a subpath import is absent from the host's exports map,
// or when a BARE import names a package the host does not ship at all and it is
// a server import. Bare client-table imports are left to the runtime.
function classifyMissing(specifier, role, fromDir) {
  const hasSub = specifier.slice('@deepseek-ai/'.length).includes('/')
  if (role === 'client' && !hasSub) return 'table'   // browser module table entry
  try {
    // Resolve through the plugin's OWN resolution chain (which reaches the dsh
    // install and the profile module fallback exactly as the runtime would).
    require.resolve(specifier, { paths: [fromDir] })
    return 'ok'
  } catch {
    return 'missing'
  }
}

function probePlugin(pluginDir, pkgJson) {
  const seen = new Set()
  for (const role of ['server', 'client']) {
    for (const file of entryFiles(pluginDir, pkgJson, role)) {
      let text
      try { text = readFileSync(file, 'utf8') } catch { continue }
      for (const m of text.matchAll(IMPORT_RE)) {
        const spec = m[1] || m[2]
        if (spec) seen.add(role + '|' + spec)
      }
    }
  }
  const missing = []
  const table = []
  let ok = 0
  for (const tagged of seen) {
    const bar = tagged.indexOf('|')
    const role = tagged.slice(0, bar)
    const spec = tagged.slice(bar + 1)
    const verdict = classifyMissing(spec, role, pluginDir)
    if (verdict === 'missing') missing.push(spec)
    else if (verdict === 'table') table.push(spec)
    else ok++
  }
  return { missing, table, ok }
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

  // --- verdict: three levels ---
  //   REJECT (!!) : hard evidence - manifest range violated, OR the smoke probe
  //                 proved the plugin imports a host subpath that does not exist
  //   WARN  (??)  : soft signal only - an explicit release list that does not
  //                 (yet) mention this host version, with no other objection.
  //                 The author may simply not have updated the list.
  //   ok / --     : compatible, or nothing declared.
  const reject = []
  const warn = []

  if (dshEngineRange && satisfies(dshEngineRange, hostVersion) === false) {
    reject.push(`engines.dsh requires ${dshEngineRange}`)
  }

  const peerRanges = []
  for (const [dep, range] of hostPeerEntries) {
    if (dep === '@deepseek-ai/cordis' || dep === '@deepseek-ai/schemastery') continue
    const installed = hostSubversion(dep)
    const ok = installed ? satisfies(range, installed) : undefined
    if (ok === false) {
      reject.push(`${dep} wants ${range}, host has ${installed}`)
    } else {
      peerRanges.push(`${dep}@${range}`)
    }
  }

  // Known transitive/runtime conflicts that package manifests cannot express.
  if (hostIs012 && name === '@linxin666/dsh-web-all' && version && semver && semver.lt(version, '0.3.9')) {
    reject.push('known: web-all <0.3.9 pins better-sidebar 0.15.x which needs settingsNamespace removed in dsh 0.1.2+')
  }

  // Smoke probe: actual imports vs actual host exports (strongest evidence).
  // Server-role bare/subpath imports must resolve in the host; client-role
  // BARE imports are browser-module-table names and are not hard failures.
  // require.resolve reflects ONLY the currently-installed host, so smoke
  // findings are hard REJECTs only when that host IS the version under test;
  // for a --host target (upgrade preview) they cannot prove the target breaks
  // and stay advisory (folded into the compatible/unknown verdict).
  const probe = probePlugin(join(profileDir, 'node_modules', name), pkg)
  if (probe.missing.length > 0 && probeApplies) {
    for (const spec of probe.missing) {
      reject.push(`smoke: imports ${spec}, not exported by this host`)
    }
  }

  if (reject.length === 0 && releaseDeclared && releaseState !== 'compatible') {
    // Only a stale/uncovered explicit list: warn, do not kill. This fixes the
    // usage-billing false-positive class (author lists old versions only).
    warn.push(`compatibility list does not (yet) cover dsh ${hostVersion}; no other conflict found`)
  }

  if (reject.length > 0) {
    lines.push(`  !! ${name}@${version}  CONFLICT on dsh ${hostVersion}: ${reject.join('; ')}`)
  } else if (warn.length > 0) {
    lines.push(`  ?? ${name}@${version}  WARN on dsh ${hostVersion}: ${warn.join('; ')}`)
  } else if (dshEngineRange || releaseState === 'compatible' || hostPeerEntries.length > 0 || probe.ok > 0) {
    lines.push(`  ok ${name}@${version}  compatible with dsh ${hostVersion}`)
  } else {
    lines.push(`  -- ${name}@${version}  no host-version declaration (low risk, unverified)`)
  }
}

if (thirdParty.length === 0) lines.push('  (no third-party plugins installed)')

// Machine-readable name modes keep the extraction regex in THIS one file, so the
// macOS (bash) and Windows (PowerShell) flows never re-implement it.
if (conflictNamesOnly || warnNamesOnly || verdictNames) {
  const emit = []
  for (const line of lines) {
    const m = line.match(/^  (!!|\?\?) (@[a-z0-9._-]+\/[a-z0-9._-]+|[a-z0-9][a-z0-9._-]*)@[0-9][^ ]*/)
    if (!m) continue
    if (verdictNames) emit.push(`${m[1]}\t${m[2]}`)
    else if (conflictNamesOnly && m[1] === '!!') emit.push(m[2])
    else if (warnNamesOnly && m[1] === '??') emit.push(m[2])
  }
  console.log(emit.join('\n'))
} else {
  console.log(lines.join('\n'))
}

