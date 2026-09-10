#!/usr/bin/env node
// dsh-agent-preset-compat-check.mjs  (cross-platform, SINGLE SOURCE at deploy/shared/)
// Pre-flight for AGENT PRESETS: validate every row of a preset's
// agent.cordis.yml against the runtime schema (the plugin's exported `Config`)
// of the module that row mounts, resolved through the profile's module tree.
//
// Why this exists: a preset IS a composition, and a row whose config no longer
// matches the installed plugin fails at MOUNT time - every new session and every
// resume dies with "preset ... failed to mount", while the upgrade-time plugin
// pre-flight (dsh-web-plugin-compat-check.mjs) sees nothing wrong, because the
// preset may be residue from an uninstalled plugin or authored by hand.
// Real case: dsh 0.1.5 renamed @deepseek-ai/dsh-persona's config key `text` to
// `prefix`; a preset written against 0.1.2 then broke every session.
//
// Usage:
//   node dsh-agent-preset-compat-check.mjs [preset-id-or-dir ...] [options]
//     --profile <name>  profile whose module resolution to use (default: web)
//     --home <dir>      harness home (default: $DSH_HOME, else ~/.dsh)
//     --json            machine-readable result array
//     --quiet           only failures plus the summary line
//   With no argument, every preset under <home>/.agent-presets is checked; an
//   id resolves to <home>/.agent-presets/<id>, a path is used as given.
//
// Rows:
//   ok    <row> [<plugin>@<version>]        config passes the plugin's schema
//   ok?   <row> [<plugin>@<version>]        plugin exports no `Config` (not schema-checked)
//   skip  <row> [<plugin>]                  row disabled (literal or !!js expression)
//   FAIL  <row> [<plugin>@<version>] - ...  unresolved row, import error, or invalid config
//
// Exit: 0 = nothing to check or every row valid; 1 = at least one row fails;
//       2 = usage error or the `yaml` parser could not be loaded.

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'
import { dirname, basename, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const USAGE =
  'usage: node dsh-agent-preset-compat-check.mjs [preset-id-or-dir ...] ' +
  '[--profile <name>] [--home <dir>] [--json] [--quiet]'

/** Abort with a usage error (exit 2: nothing was validated). */
function usageError(message) {
  console.error(`dsh-agent-preset-compat-check: ${message}`)
  console.error(USAGE)
  process.exit(2)
}

const options = {
  profile: 'web',
  home: process.env.DSH_HOME || join(homedir(), '.dsh'),
  json: false,
  quiet: false,
}
const targets = []
const argv = process.argv.slice(2)
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i]
  if (arg === '--json') options.json = true
  else if (arg === '--quiet') options.quiet = true
  else if (arg === '--profile' || arg === '--home') {
    const value = argv[i + 1]
    if (value === undefined || value.startsWith('--')) usageError(`missing value for ${arg}`)
    if (arg === '--profile') options.profile = value
    else options.home = value
    i += 1
  } else if (arg === '-h' || arg === '--help') {
    console.log(USAGE)
    process.exit(0)
  } else if (arg.startsWith('--')) usageError(`unknown option: ${arg}`)
  else targets.push(arg)
}

const profileDir = join(options.home, 'profiles', options.profile)
const presetRoot = join(options.home, '.agent-presets')
const baseRequire = createRequire(join(profileDir, 'noop.mjs'))

/** Roots a row's plugin resolves through, most specific first. */
const searchPaths = [
  join(profileDir, 'node_modules'),
  join(options.home, 'profiles', 'node_modules'),
  join(profileDir, '.dsh-module-fallback', 'node_modules'),
]

/** The installed @deepseek-ai/dsh directory, or undefined when dsh is not on PATH. */
function dshInstallRoot() {
  try {
    if (process.platform === 'win32') {
      const prefix = execSync('npm prefix -g', { encoding: 'utf8', shell: process.env.ComSpec || 'cmd.exe' }).trim()
      const candidate = join(prefix, 'node_modules', '@deepseek-ai', 'dsh')
      return existsSync(join(candidate, 'package.json')) ? candidate : undefined
    }
    const bin = execSync('command -v dsh', { encoding: 'utf8' }).trim()
    const real = execSync(`readlink -f "${bin}"`, { encoding: 'utf8' }).trim()
    const at = real.indexOf('lib/node_modules')
    if (at === -1) return undefined
    const candidate = `${real.slice(0, at)}lib/node_modules/@deepseek-ai/dsh`
    return existsSync(join(candidate, 'package.json')) ? candidate : undefined
  } catch {
    return undefined
  }
}

const dshRoot = dshInstallRoot()
if (dshRoot) searchPaths.push(join(dshRoot, 'node_modules'))

/** Load the `yaml` parser from the harness dependency trees. */
function loadYaml() {
  const roots = [join(options.home, 'profiles', 'node_modules')]
  if (dshRoot) roots.push(join(dshRoot, 'node_modules'))
  for (const root of roots) {
    try {
      const mod = createRequire(join(root, 'noop.js'))('yaml')
      if (typeof mod.parse === 'function') return mod
    } catch {
      // try the next dependency tree
    }
  }
  usageError('cannot load the `yaml` package from the harness dependency trees')
}

/** Parse JSON, or undefined when the file is absent or unreadable. */
function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return undefined
  }
}

/** The package entry a bare specifier maps to. */
function entryFile(pkg) {
  const root = pkg.exports?.['.']
  if (typeof root === 'string') return root
  if (root && typeof root.default === 'string') return root.default
  if (typeof pkg.main === 'string') return pkg.main
  return 'index.js'
}

/** The file a subpath export maps to, or undefined when it is undeclared. */
function exportsTarget(exportsMap, subpath) {
  const target = exportsMap?.[subpath]
  if (typeof target === 'string') return target
  if (target && typeof target.default === 'string') return target.default
  return undefined
}

/**
 * Resolve a row's plugin specifier to a file, following the profile's module
 * trees, the package `exports` map, and subpath exports.
 * @param spec - the row's `name` (`./local.mjs`, `@scope/pkg`, `@scope/pkg/sub`).
 * @param fromDir - preset directory a relative specifier resolves against.
 * @returns `{ file }` or `{ error }`.
 */
function resolveSpecifier(spec, fromDir) {
  if (spec.startsWith('./') || spec.startsWith('../')) {
    const file = resolve(fromDir, spec)
    return existsSync(file) ? { file } : { error: `missing preset file ${file}` }
  }
  try {
    return { file: baseRequire.resolve(spec, { paths: [fromDir, ...searchPaths] }) }
  } catch {
    // ESM-only export maps can defeat require.resolve; walk the trees directly.
  }
  for (const base of searchPaths) {
    const segments = spec.split('/')
    for (let take = segments.length; take >= 2; take -= 1) {
      const pkgDir = join(base, segments.slice(0, take).join('/'))
      const pkg = readJson(join(pkgDir, 'package.json'))
      if (pkg === undefined) continue
      const subpath = take === segments.length ? undefined : `./${segments.slice(take).join('/')}`
      const entry = subpath === undefined ? entryFile(pkg) : exportsTarget(pkg.exports, subpath)
      if (entry === undefined) continue
      const file = join(pkgDir, entry)
      return existsSync(file) ? { file } : { error: `declared entry is missing: ${file}` }
    }
  }
  return { error: `not resolvable (searched ${[fromDir, ...searchPaths].join(', ')})` }
}

/** The plugin name and version owning a resolved file. */
function packageOf(file) {
  let dir = dirname(file)
  for (;;) {
    const pkg = readJson(join(dir, 'package.json'))
    if (pkg !== undefined) return { name: pkg.name, version: pkg.version }
    const parent = dirname(dir)
    if (parent === dir) return {}
    dir = parent
  }
}

/** One-line rendering of a thrown value (schemastery messages are multi-line). */
function stringify(error) {
  const text = error instanceof Error ? error.message : String(error)
  return text.replace(/\s*\n\s*/g, ' | ').trim()
}

/** Every plugin row of a preset, depth-first, with group rows marked. */
function rowsOf(entries, depth = 0, out = []) {
  if (!Array.isArray(entries)) return out
  for (const entry of entries) {
    if (entry === null || typeof entry !== 'object') continue
    if (Array.isArray(entry.config)) {
      out.push({ id: entry.id, group: true, depth })
      rowsOf(entry.config, depth + 1, out)
      continue
    }
    if (typeof entry.name === 'string' || Array.isArray(entry.name)) out.push({ ...entry, depth })
    else if (entry.id !== undefined) out.push({ id: entry.id, unnamed: true, depth })
  }
  return out
}

/** Preset directories to check: explicit targets, else every user preset. */
function presetDirs() {
  try {
    if (targets.length > 0) {
      return targets.map((target) => {
        const asPath = resolve(target)
        const dir = existsSync(join(asPath, 'agent.cordis.yml')) ? asPath : join(presetRoot, target)
        if (!existsSync(join(dir, 'agent.cordis.yml'))) usageError(`no agent.cordis.yml under ${dir}`)
        return dir
      })
    }
    if (!existsSync(presetRoot)) return []
    return readdirSync(presetRoot)
      .map((entry) => join(presetRoot, entry))
      .filter((dir) => statSync(dir).isDirectory() && existsSync(join(dir, 'agent.cordis.yml')))
      .sort()
  } catch (error) {
    return usageError(error instanceof Error ? error.message : String(error))
  }
}

const yaml = loadYaml()
// `!!js` expressions run on the host and never reach a plugin schema; keep them
// as a marker so `disabled:` is reported rather than evaluated here.
const jsTag = { tag: '!!js', resolve: (value) => ({ js: value }) }

const results = []
const dirs = presetDirs()
for (const dir of dirs) {
  const preset = basename(dir)
  let rows
  try {
    rows = rowsOf(yaml.parse(readFileSync(join(dir, 'agent.cordis.yml'), 'utf8'), { customTags: [jsTag] }))
  } catch (error) {
    results.push({ preset, row: '(file)', status: 'FAIL', error: stringify(error) })
    continue
  }
  for (const row of rows) {
    const rowLabel = `${'  '.repeat(row.depth)}${row.id ?? '(anonymous)'}`
    if (row.group) {
      results.push({ preset, row: rowLabel, status: 'group' })
      continue
    }
    if (row.unnamed) {
      results.push({ preset, row: rowLabel, status: 'FAIL', error: 'row has no `name`' })
      continue
    }
    const specs = Array.isArray(row.name) ? row.name : [row.name]
    for (const spec of specs) {
      const result = { preset, row: rowLabel, plugin: spec, status: 'ok' }
      if (row.disabled !== undefined && row.disabled !== false) {
        result.status = 'skip'
        result.error = typeof row.disabled === 'object' ? 'disabled: !!js expression' : `disabled: ${row.disabled}`
        results.push(result)
        continue
      }
      const resolved = resolveSpecifier(spec, dir)
      if (resolved.error !== undefined) {
        results.push({ ...result, status: 'FAIL', error: resolved.error })
        continue
      }
      const pkg = packageOf(resolved.file)
      result.plugin = pkg.name ?? spec
      result.version = pkg.version
      let mod
      try {
        mod = await import(pathToFileURL(resolved.file).href)
      } catch (error) {
        results.push({ ...result, status: 'FAIL', error: `import error: ${stringify(error)}` })
        continue
      }
      if (typeof mod.Config !== 'function') {
        results.push({ ...result, status: 'unchecked', error: 'plugin exports no `Config`' })
        continue
      }
      try {
        mod.Config(row.config ?? {})
        results.push(result)
      } catch (error) {
        results.push({ ...result, status: 'FAIL', error: stringify(error) })
      }
    }
  }
}

const failing = results.filter((result) => result.status === 'FAIL').length
if (options.json) {
  console.log(JSON.stringify({ presetRoot: dirs.length > 0 ? presetRoot : null, results, failing }, null, 2))
} else {
  for (const result of results) {
    if (options.quiet && result.status !== 'FAIL' && result.status !== 'group') continue
    const where = result.version === undefined ? result.plugin : `${result.plugin}@${result.version}`
    if (result.status === 'group') console.log(`group ${result.row}`)
    else if (result.status === 'ok') console.log(`ok    ${result.row} [${where}]`)
    else if (result.status === 'unchecked') console.log(`ok?   ${result.row} [${where}] - ${result.error}`)
    else if (result.status === 'skip') console.log(`skip  ${result.row} [${result.plugin}] - ${result.error}`)
    else console.log(`FAIL  ${result.row} [${where}] - ${result.error}`)
  }
  console.log('')
  console.log(
    `${dirs.length} preset(s), ${results.filter((r) => r.status !== 'group').length} row(s) checked, ${failing} failing`,
  )
}
process.exit(failing > 0 ? 1 : 0)
