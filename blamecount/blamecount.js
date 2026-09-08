#!/usr/bin/env node
// blamecount: count lines by each contributor
// 2016  David Ulrich
//
// CC0: This work has been marked as dedicated to the public domain.
// https://creativecommons.org/publicdomain/zero/1.0/
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFile } = require("node:child_process");
const { promisify } = require("node:util");

const execFileAsync = promisify(execFile);

// Generous buffer for "git ls-files"/"git blame" output on real repos.
const EXEC_MAX_BUFFER = 32 * 1024 * 1024;

const EXIT = {
	OK: 0,
	USAGE: 1,
	CONFIG_READ: 2,
	CONFIG_PARSE: 3,
	CONFIG_INVALID: 4,
	NOT_A_REPO: 5,
	LS_FILES_FAILED: 6,
	BLAME_FAILED: 7,
};

class BlamecountError extends Error {
	constructor(code, message) {
		super(message);
		this.code = code;
	}
}

const DEFAULT_CONCURRENCY = 4;

// Fixed language table: an extension not listed here is silently dropped
// from the totals (a file is still blamed, its lines just aren't counted).
const LANGUAGE_TABLE = Object.freeze({
	c: 0, cc: 0, cpp: 0, cs: 0, css: 0, h: 0, htm: 0, html: 0, js: 0,
	less: 0, lua: 0, php: 0, pl: 0, py: 0, rb: 0, sh: 0, sql: 0,
});

const MINIFIED_RE = /.+\.min\.(js|css)$/i;

const HELP_TEXT = `blamecount: count tracked lines by author and language via "git blame"

Usage: node blamecount.js [--config <path>] [-h|--help]

  --config <path>  Path to the JSON config (default: config.json beside
                    this script). Config fields:
                      basepath     (required) path to a Git work tree
                      stopdirs     (optional) array of relative directory
                                   paths to exclude entirely. An entry is
                                   matched against the exact incremental
                                   relative directory path built from the
                                   root, so a bare name like "node_modules"
                                   only stops a top-level directory of that
                                   name -- a same-named nested directory
                                   (e.g. "src/node_modules") is not stopped.
                      concurrency  (optional) max concurrent "git blame"
                                   child processes (default ${DEFAULT_CONCURRENCY})
  -h, --help       Print this help and exit 0

Output: exactly one JSON object on stdout with sorted keys, mapping author
name to a per-language line-count object (every table language present,
zero where the author has no lines); everything else goes to stderr.

Uncommitted/unstaged lines are reported by "git blame" under the literal
author "Not Committed Yet" (with the all-zero commit hash) and are counted
under that literal author name, not skipped.

Tracked symlinks are skipped, matching the tool's historical behavior.

Exit codes:
  ${EXIT.OK}  success
  ${EXIT.USAGE}  bad command-line usage
  ${EXIT.CONFIG_READ}  config file missing or unreadable
  ${EXIT.CONFIG_PARSE}  config file is not valid JSON
  ${EXIT.CONFIG_INVALID}  config is missing/invalid required fields
  ${EXIT.NOT_A_REPO}  basepath is not a Git work tree
  ${EXIT.LS_FILES_FAILED}  "git ls-files" failed
  ${EXIT.BLAME_FAILED}  "git blame" failed for one or more files
`;

function parseArgv(argv) {
	let configPath = null;

	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];

		if (arg === "-h" || arg === "--help") {
			return { help: true, configPath: null };
		}

		if (arg === "--config") {
			const value = argv[i + 1];
			if (value === undefined) {
				throw new BlamecountError(EXIT.USAGE, "blamecount: --config requires a path argument");
			}
			configPath = value;
			i++;
			continue;
		}

		if (arg.startsWith("--config=")) {
			configPath = arg.slice("--config=".length);
			continue;
		}

		throw new BlamecountError(EXIT.USAGE, `blamecount: unrecognized argument '${arg}'`);
	}

	return { help: false, configPath };
}

function loadConfig(configPath) {
	let raw;
	try {
		raw = fs.readFileSync(configPath, "utf8");
	} catch (err) {
		throw new BlamecountError(
			EXIT.CONFIG_READ,
			`blamecount: cannot read config '${configPath}': ${err.message}`
		);
	}

	let parsed;
	try {
		parsed = JSON.parse(raw);
	} catch (err) {
		throw new BlamecountError(
			EXIT.CONFIG_PARSE,
			`blamecount: config '${configPath}' is not valid JSON: ${err.message}`
		);
	}

	if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
		throw new BlamecountError(
			EXIT.CONFIG_INVALID,
			`blamecount: config '${configPath}' must contain a JSON object`
		);
	}

	if (typeof parsed.basepath !== "string" || parsed.basepath.length === 0) {
		throw new BlamecountError(
			EXIT.CONFIG_INVALID,
			`blamecount: config '${configPath}' requires a non-empty string field 'basepath'`
		);
	}

	let stopdirs = [];
	if (parsed.stopdirs !== undefined) {
		if (!Array.isArray(parsed.stopdirs) || !parsed.stopdirs.every((d) => typeof d === "string")) {
			throw new BlamecountError(
				EXIT.CONFIG_INVALID,
				`blamecount: config '${configPath}' field 'stopdirs' must be an array of strings`
			);
		}
		stopdirs = parsed.stopdirs;
	}

	let concurrency = DEFAULT_CONCURRENCY;
	if (parsed.concurrency !== undefined) {
		if (!Number.isInteger(parsed.concurrency) || parsed.concurrency < 1) {
			throw new BlamecountError(
				EXIT.CONFIG_INVALID,
				`blamecount: config '${configPath}' field 'concurrency' must be a positive integer`
			);
		}
		concurrency = parsed.concurrency;
	}

	return { basepath: parsed.basepath, stopdirs, concurrency };
}

function firstLine(text) {
	if (!text) return "";
	return String(text).split("\n")[0];
}

async function assertGitWorkTree(basepath) {
	let result;
	try {
		result = await execFileAsync(
			"git",
			["-C", basepath, "rev-parse", "--is-inside-work-tree"],
			{ maxBuffer: EXEC_MAX_BUFFER }
		);
	} catch (err) {
		throw new BlamecountError(
			EXIT.NOT_A_REPO,
			`blamecount: basepath '${basepath}' is not a Git work tree: ${firstLine(err.stderr) || err.message}`
		);
	}

	if (result.stdout.trim() !== "true") {
		throw new BlamecountError(
			EXIT.NOT_A_REPO,
			`blamecount: basepath '${basepath}' is not a Git work tree`
		);
	}
}

// NUL-delimited, whitespace-safe tracked-file discovery. "--stage" carries
// the index file mode alongside each path so a tracked symlink (mode
// 120000) can be skipped from Git's own metadata, with no separate
// filesystem stat (and no separate error class for a working-tree file
// that has since gone missing).
async function listTrackedFiles(basepath) {
	let result;
	try {
		result = await execFileAsync(
			"git",
			["-C", basepath, "ls-files", "-z", "--stage"],
			{ maxBuffer: EXEC_MAX_BUFFER }
		);
	} catch (err) {
		throw new BlamecountError(
			EXIT.LS_FILES_FAILED,
			`blamecount: 'git ls-files' failed in '${basepath}': ${firstLine(err.stderr) || err.message}`
		);
	}

	const files = [];
	for (const entry of result.stdout.split("\0")) {
		if (entry.length === 0) continue;

		const tabIndex = entry.indexOf("\t");
		if (tabIndex === -1) continue;

		const meta = entry.slice(0, tabIndex);
		const file = entry.slice(tabIndex + 1);
		const mode = meta.split(" ")[0];

		if (mode === "120000") continue; // tracked symlink: preserve the historical silent skip

		files.push(file);
	}
	return files;
}

// Preserves the original's top-level-only stop-dir semantics: the original
// recursive walk only ever compared a directory's exact incrementally-built
// relative path against the configured names, so a same-named directory
// nested deeper in the tree was never stopped. Reproduced here by checking
// every ancestor directory path of a file (built the same way) against the
// configured set, without a directory-by-directory filesystem walk.
function isUnderStopDir(file, stopdirs) {
	if (stopdirs.length === 0) return false;

	const slash = file.lastIndexOf("/");
	if (slash === -1) return false; // top-level file: no ancestor directory

	const dir = file.slice(0, slash);
	const segments = dir.split("/");
	let acc = "";
	for (const seg of segments) {
		acc = acc === "" ? seg : `${acc}/${seg}`;
		if (stopdirs.includes(acc)) return true;
	}
	return false;
}

// Language key: the last "."-segment of the filename (not the full path).
function languageOf(file) {
	const base = file.slice(file.lastIndexOf("/") + 1);
	const dot = base.lastIndexOf(".");
	if (dot === -1) return base;
	return base.slice(dot + 1);
}

// Every physical line of a blamed file gets its own porcelain header line
// (`<sha> <origline> <finalline>[ <groupsize>]`); the optional 4th field is
// only present on the first header line of a contiguous group and is not
// needed here, since counting header lines already counts lines. Per-commit
// metadata (including the "author" line) is only emitted the first time a
// given commit appears anywhere in this file's output, so authors are
// resolved through a cache keyed by commit sha.
const HEADER_RE = /^([0-9a-f]{40}) \d+ \d+(?: \d+)?$/;
const AUTHOR_RE = /^author (.*)$/;

async function blameFile(basepath, file) {
	let result;
	try {
		result = await execFileAsync(
			"git",
			["-C", basepath, "blame", "--porcelain", "--", file],
			{ maxBuffer: EXEC_MAX_BUFFER }
		);
	} catch (err) {
		throw new BlamecountError(
			EXIT.BLAME_FAILED,
			`blamecount: 'git blame' failed for '${file}': ${firstLine(err.stderr) || err.message}`
		);
	}

	const shaCounts = new Map();
	const shaAuthors = new Map();
	let currentSha = null;

	for (const line of result.stdout.split("\n")) {
		if (line.length === 0) continue;
		if (line.charAt(0) === "\t") continue; // blamed file content line

		const header = HEADER_RE.exec(line);
		if (header) {
			currentSha = header[1];
			shaCounts.set(currentSha, (shaCounts.get(currentSha) || 0) + 1);
			continue;
		}

		if (currentSha !== null && !shaAuthors.has(currentSha)) {
			const author = AUTHOR_RE.exec(line);
			if (author) {
				shaAuthors.set(currentSha, author[1]);
			}
		}
	}

	const lang = languageOf(file);
	const counted = [];
	for (const [sha, count] of shaCounts) {
		const author = shaAuthors.get(sha);
		if (author === undefined) {
			throw new BlamecountError(
				EXIT.BLAME_FAILED,
				`blamecount: 'git blame' for '${file}' produced no author metadata for commit '${sha}'`
			);
		}
		counted.push({ author, lang, count });
	}
	return counted;
}

// Bounded worker pool: at most `limit` concurrent "git blame" child
// processes. Every item is attempted exactly once; a failing item records
// its error and does not stop other in-flight or queued items, so a single
// bad file produces one attributable error alongside every other file's
// normal result rather than an early, partial abort.
async function mapWithConcurrency(items, limit, fn) {
	const results = [];
	const errors = [];
	let index = 0;

	async function worker() {
		for (;;) {
			const current = index++;
			if (current >= items.length) return;
			try {
				results.push(await fn(items[current]));
			} catch (err) {
				errors.push(err);
			}
		}
	}

	const workerCount = Math.max(1, Math.min(limit, items.length));
	await Promise.all(Array.from({ length: workerCount }, () => worker()));

	return { results, errors };
}

function cloneLanguageTable() {
	return Object.assign({}, LANGUAGE_TABLE);
}

// Explicit accumulator, no module-level mutable totals: the caller owns the
// object and threads it through the call chain.
function addLines(totals, author, lang, count) {
	if (!Object.prototype.hasOwnProperty.call(totals, author)) {
		totals[author] = cloneLanguageTable();
	}
	if (!Object.prototype.hasOwnProperty.call(totals[author], lang)) return;
	totals[author][lang] += count;
}

function sortedClone(value) {
	if (Array.isArray(value)) return value.map(sortedClone);
	if (value !== null && typeof value === "object") {
		const out = {};
		for (const key of Object.keys(value).sort()) {
			out[key] = sortedClone(value[key]);
		}
		return out;
	}
	return value;
}

async function run(argv) {
	const args = parseArgv(argv);
	if (args.help) {
		process.stdout.write(HELP_TEXT);
		return EXIT.OK;
	}

	const configPath = args.configPath || path.join(__dirname, "config.json");
	const config = loadConfig(configPath);
	const basepath = config.basepath;

	await assertGitWorkTree(basepath);

	const allFiles = await listTrackedFiles(basepath);
	const files = allFiles.filter((file) => {
		if (isUnderStopDir(file, config.stopdirs)) return false;
		if (MINIFIED_RE.test(file)) return false;
		return true;
	});

	const { results, errors } = await mapWithConcurrency(
		files,
		config.concurrency,
		(file) => blameFile(basepath, file)
	);

	if (errors.length > 0) {
		for (const err of errors) {
			process.stderr.write(`${err.message}\n`);
		}
		return errors[0].code || EXIT.BLAME_FAILED;
	}

	const totals = {};
	for (const perFile of results) {
		for (const { author, lang, count } of perFile) {
			addLines(totals, author, lang, count);
		}
	}

	process.stdout.write(`${JSON.stringify(sortedClone(totals))}\n`);
	return EXIT.OK;
}

run(process.argv.slice(2))
	.then((code) => {
		process.exitCode = code;
	})
	.catch((err) => {
		if (err instanceof BlamecountError) {
			process.stderr.write(`${err.message}\n`);
			process.exitCode = err.code;
			return;
		}
		process.stderr.write(`blamecount: unexpected error: ${err && err.stack ? err.stack : err}\n`);
		process.exitCode = 99;
	});
