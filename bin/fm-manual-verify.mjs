#!/usr/bin/env node
/**
 * Generate one private, revision-bound Lavish manual-verification artifact.
 *
 * Usage:
 *   fm-manual-verify.mjs generate <spec.json>
 *   fm-manual-verify.mjs submission <artifact.html> <answers.json>
 *   fm-manual-verify.mjs --help
 *
 * `generate` validates a bounded JSON schema and writes only to
 * `$FM_HOME/data/<taskId>/manual-verification.html` at mode 0600.
 * It prints JSON containing the artifact identity and an ordered argv plan.
 * Execute that plan in order: create the Lavish session without opening it,
 * arm Firstmate's registered process-event adapter, then present the page.
 *
 * `submission` runs the exact validation and submission builder embedded in
 * the artifact. It is a preflight and behavior-test surface, not a replacement
 * for submitting through `window.lavish.queuePrompt` in the rendered page.
 */

import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(SCRIPT_PATH), "..");
const SCHEMA_VERSION = 1;
const ARTIFACT_FILENAME = "manual-verification.html";
const TOP_LEVEL_KEYS = new Set([
  "schemaVersion",
  "taskId",
  "verificationType",
  "project",
  "issue",
  "issueUrl",
  "prUrl",
  "revision",
  "environment",
  "staleCheck",
  "loginUrl",
  "account",
  "testUrl",
  "preconditions",
  "blastRadius",
  "restoration",
  "purpose",
  "userOutcome",
  "contextFields",
  "sections",
  "steps",
]);
const VERIFICATION_TYPES = new Set([
  "browser-editor",
  "browser",
  "backend-api",
  "migration-data",
  "operational-tool",
  "other",
]);
const FIELD_TYPES = new Set(["text", "textarea", "select"]);
const STEP_STATUSES = new Set(["PASS", "FAIL", "BLOCKED", "NOT_RUN"]);
const REPEATABILITY_VALUES = new Set([
  "EVERY_TIME",
  "SOMETIMES",
  "ONCE",
  "COULD_NOT_REPEAT",
  "NOT_APPLICABLE",
  "NOT_RUN",
]);
const IMPACT_VALUES = new Set(["BLOCKING", "NON_BLOCKING", "UNKNOWN", "NOT_APPLICABLE"]);
const HEALTH_VALUES = new Set(["PASS", "FAIL", "NOT_CHECKED", "NOT_APPLICABLE"]);
const RESTORATION_VALUES = new Set(["RESTORED", "NOT_NEEDED", "PENDING", "FAILED", "NOT_RUN"]);
const OVERALL_VALUES = new Set(["PASS", "FAIL", "BLOCKED", "PARTIAL"]);

class InputError extends Error {
  constructor(errors) {
    super("invalid manual-verification input");
    this.errors = errors;
  }
}

function usage(stream = process.stdout) {
  stream.write(`fm-manual-verify.mjs - private structured manual verification\n\n`);
  stream.write(`Usage:\n`);
  stream.write(`  fm-manual-verify.mjs generate <spec.json>\n`);
  stream.write(`  fm-manual-verify.mjs submission <artifact.html> <answers.json>\n\n`);
  stream.write(`The generator accepts JSON only and writes exactly:\n`);
  stream.write(`  $FM_HOME/data/<taskId>/manual-verification.html\n\n`);
  stream.write(`Required top-level fields:\n`);
  stream.write(`  schemaVersion, taskId, verificationType, project, issue, revision,\n`);
  stream.write(`  environment, staleCheck, loginUrl, account, testUrl, preconditions,\n`);
  stream.write(`  blastRadius, restoration, purpose, userOutcome, contextFields,\n`);
  stream.write(`  sections, steps\n\n`);
  stream.write(`verificationType values:\n`);
  stream.write(`  browser-editor, browser, backend-api, migration-data, operational-tool, other\n\n`);
  stream.write(`Each context field has id, label, type, required, and optional help/options.\n`);
  stream.write(`Each section has title, optional description, and fields.\n`);
  stream.write(`Each step has id, title, setup, action, and expected.\n`);
  stream.write(`issueUrl and prUrl are optional. prUrl must be a full HTTPS URL when present.\n`);
  stream.write(`HTTP access URLs are accepted only for loopback hosts; other access URLs require HTTPS.\n`);
}

function readJson(path, label) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    throw new InputError([{ path: label, message: `cannot read ${path}: ${error.message}` }]);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new InputError([{ path: label, message: `invalid JSON: ${error.message}` }]);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function rejectUnknownKeys(value, allowed, path, errors) {
  if (!isPlainObject(value)) return;
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) errors.push({ path: `${path}.${key}`, message: "unknown field" });
  }
}

function requiredString(value, path, errors, { max = 10000 } = {}) {
  if (typeof value !== "string" || value.trim() === "") {
    errors.push({ path, message: "must be a non-empty string" });
    return "";
  }
  const normalized = value.trim();
  if (normalized.length > max) errors.push({ path, message: `must be at most ${max} characters` });
  if (/\p{Cc}/u.test(normalized)) errors.push({ path, message: "must not contain control characters" });
  return normalized;
}

function optionalString(value, path, errors, options) {
  if (value === undefined || value === null || value === "") return null;
  return requiredString(value, path, errors, options);
}

function validateSlug(value, path, errors, max = 96) {
  const normalized = requiredString(value, path, errors, { max });
  if (normalized && !/^[a-z0-9][a-z0-9._-]*$/.test(normalized)) {
    errors.push({ path, message: "must start with a lowercase letter or digit and contain only lowercase letters, digits, dots, underscores, or hyphens" });
  }
  return normalized;
}

function validateFieldId(value, path, errors) {
  const normalized = requiredString(value, path, errors, { max: 64 });
  if (normalized && !/^[a-z][a-z0-9_]*$/.test(normalized)) {
    errors.push({ path, message: "must start with a lowercase letter and contain only lowercase letters, digits, or underscores" });
  }
  return normalized;
}

function validateRevision(value, path, errors) {
  const normalized = requiredString(value, path, errors, { max: 256 });
  if (normalized && !/^[A-Za-z0-9][A-Za-z0-9._:+@/-]*$/.test(normalized)) {
    errors.push({ path, message: "must be an exact revision or environment identity using letters, digits, dots, underscores, colons, plus, at, slash, or hyphen" });
  }
  return normalized;
}

function validateUrl(value, path, errors, { optional = false, httpsOnly = false } = {}) {
  if (optional && (value === undefined || value === null || value === "")) return null;
  const normalized = requiredString(value, path, errors, { max: 2048 });
  if (!normalized) return "";
  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    errors.push({ path, message: "must be a full absolute URL" });
    return normalized;
  }
  if (parsed.username || parsed.password) {
    errors.push({ path, message: "must not embed a username, password, token, or other URL credential" });
  }
  const host = parsed.hostname.toLowerCase();
  const loopback = host === "localhost" || host === "127.0.0.1" || host === "::1" || host.endsWith(".localhost");
  if (httpsOnly) {
    if (parsed.protocol !== "https:") errors.push({ path, message: "must use HTTPS" });
  } else if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback)) {
    errors.push({ path, message: "must use HTTPS, except that HTTP is allowed for loopback hosts" });
  }
  return parsed.toString();
}

function validateField(value, path, errors, seenIds) {
  const allowed = new Set(["id", "label", "type", "required", "help", "options"]);
  if (!isPlainObject(value)) {
    errors.push({ path, message: "must be an object" });
    return null;
  }
  rejectUnknownKeys(value, allowed, path, errors);
  const id = validateFieldId(value.id, `${path}.id`, errors);
  if (id) {
    if (seenIds.has(id)) errors.push({ path: `${path}.id`, message: `duplicate field id: ${id}` });
    seenIds.add(id);
  }
  const label = requiredString(value.label, `${path}.label`, errors, { max: 160 });
  const type = requiredString(value.type, `${path}.type`, errors, { max: 20 });
  if (type && !FIELD_TYPES.has(type)) {
    errors.push({ path: `${path}.type`, message: `must be one of: ${[...FIELD_TYPES].join(", ")}` });
  }
  if (typeof value.required !== "boolean") errors.push({ path: `${path}.required`, message: "must be true or false" });
  const help = optionalString(value.help, `${path}.help`, errors, { max: 1000 });
  let options = [];
  if (type === "select") {
    if (!Array.isArray(value.options) || value.options.length < 1 || value.options.length > 30) {
      errors.push({ path: `${path}.options`, message: "must contain between 1 and 30 options for a select field" });
    } else {
      const seenValues = new Set();
      options = value.options.map((option, index) => {
        const optionPath = `${path}.options[${index}]`;
        if (!isPlainObject(option)) {
          errors.push({ path: optionPath, message: "must be an object" });
          return { value: "", label: "" };
        }
        rejectUnknownKeys(option, new Set(["value", "label"]), optionPath, errors);
        const optionValue = requiredString(option.value, `${optionPath}.value`, errors, { max: 120 });
        const optionLabel = requiredString(option.label, `${optionPath}.label`, errors, { max: 240 });
        if (seenValues.has(optionValue)) errors.push({ path: `${optionPath}.value`, message: "must be unique within this field" });
        seenValues.add(optionValue);
        return { value: optionValue, label: optionLabel };
      });
    }
  } else if (value.options !== undefined) {
    errors.push({ path: `${path}.options`, message: "is allowed only for select fields" });
  }
  return { id, label, type, required: value.required === true, help, options };
}

function validateSpec(raw) {
  const errors = [];
  if (!isPlainObject(raw)) throw new InputError([{ path: "spec", message: "must be a JSON object" }]);
  rejectUnknownKeys(raw, TOP_LEVEL_KEYS, "spec", errors);
  if (raw.schemaVersion !== SCHEMA_VERSION) {
    errors.push({ path: "schemaVersion", message: `must equal ${SCHEMA_VERSION}` });
  }
  const taskId = validateSlug(raw.taskId, "taskId", errors);
  const verificationType = requiredString(raw.verificationType, "verificationType", errors, { max: 40 });
  if (verificationType && !VERIFICATION_TYPES.has(verificationType)) {
    errors.push({ path: "verificationType", message: `must be one of: ${[...VERIFICATION_TYPES].join(", ")}` });
  }
  const project = requiredString(raw.project, "project", errors, { max: 240 });
  const issue = requiredString(raw.issue, "issue", errors, { max: 500 });
  const issueUrl = validateUrl(raw.issueUrl, "issueUrl", errors, { optional: true, httpsOnly: true });
  const prUrl = validateUrl(raw.prUrl, "prUrl", errors, { optional: true, httpsOnly: true });
  const revision = validateRevision(raw.revision, "revision", errors);
  const environment = requiredString(raw.environment, "environment", errors, { max: 500 });
  const staleCheck = requiredString(raw.staleCheck, "staleCheck", errors, { max: 2000 });
  const loginUrl = validateUrl(raw.loginUrl, "loginUrl", errors);
  const account = requiredString(raw.account, "account", errors, { max: 500 });
  const testUrl = validateUrl(raw.testUrl, "testUrl", errors);
  const blastRadius = requiredString(raw.blastRadius, "blastRadius", errors, { max: 3000 });
  const restoration = requiredString(raw.restoration, "restoration", errors, { max: 3000 });
  const purpose = requiredString(raw.purpose, "purpose", errors, { max: 3000 });
  const userOutcome = requiredString(raw.userOutcome, "userOutcome", errors, { max: 3000 });

  let preconditions = [];
  if (!Array.isArray(raw.preconditions) || raw.preconditions.length < 1 || raw.preconditions.length > 30) {
    errors.push({ path: "preconditions", message: "must contain between 1 and 30 strings" });
  } else {
    preconditions = raw.preconditions.map((item, index) =>
      requiredString(item, `preconditions[${index}]`, errors, { max: 2000 }),
    );
  }

  const seenFieldIds = new Set();
  let contextFields = [];
  if (!Array.isArray(raw.contextFields) || raw.contextFields.length > 30) {
    errors.push({ path: "contextFields", message: "must be an array with at most 30 fields" });
  } else {
    contextFields = raw.contextFields
      .map((field, index) => validateField(field, `contextFields[${index}]`, errors, seenFieldIds))
      .filter(Boolean);
  }

  let sections = [];
  if (!Array.isArray(raw.sections) || raw.sections.length > 20) {
    errors.push({ path: "sections", message: "must be an array with at most 20 sections" });
  } else {
    sections = raw.sections.map((section, sectionIndex) => {
      const sectionPath = `sections[${sectionIndex}]`;
      if (!isPlainObject(section)) {
        errors.push({ path: sectionPath, message: "must be an object" });
        return { title: "", description: null, fields: [] };
      }
      rejectUnknownKeys(section, new Set(["title", "description", "fields"]), sectionPath, errors);
      const title = requiredString(section.title, `${sectionPath}.title`, errors, { max: 240 });
      const description = optionalString(section.description, `${sectionPath}.description`, errors, { max: 2000 });
      let fields = [];
      if (!Array.isArray(section.fields) || section.fields.length < 1 || section.fields.length > 30) {
        errors.push({ path: `${sectionPath}.fields`, message: "must contain between 1 and 30 fields" });
      } else {
        fields = section.fields
          .map((field, fieldIndex) => validateField(field, `${sectionPath}.fields[${fieldIndex}]`, errors, seenFieldIds))
          .filter(Boolean);
      }
      return { title, description, fields };
    });
  }

  const seenStepIds = new Set();
  let steps = [];
  if (!Array.isArray(raw.steps) || raw.steps.length < 1 || raw.steps.length > 50) {
    errors.push({ path: "steps", message: "must contain between 1 and 50 steps" });
  } else {
    steps = raw.steps.map((step, index) => {
      const stepPath = `steps[${index}]`;
      if (!isPlainObject(step)) {
        errors.push({ path: stepPath, message: "must be an object" });
        return { id: "", title: "", setup: "", action: "", expected: "" };
      }
      rejectUnknownKeys(step, new Set(["id", "title", "setup", "action", "expected"]), stepPath, errors);
      const id = validateSlug(step.id, `${stepPath}.id`, errors, 64);
      if (id) {
        if (seenStepIds.has(id)) errors.push({ path: `${stepPath}.id`, message: `duplicate step id: ${id}` });
        seenStepIds.add(id);
      }
      return {
        id,
        title: requiredString(step.title, `${stepPath}.title`, errors, { max: 240 }),
        setup: requiredString(step.setup, `${stepPath}.setup`, errors, { max: 5000 }),
        action: requiredString(step.action, `${stepPath}.action`, errors, { max: 5000 }),
        expected: requiredString(step.expected, `${stepPath}.expected`, errors, { max: 5000 }),
      };
    });
  }

  if (errors.length) throw new InputError(errors);
  const fields = [...contextFields, ...sections.flatMap((section) => section.fields)];
  return {
    schemaVersion: SCHEMA_VERSION,
    taskId,
    verificationType,
    project,
    issue,
    issueUrl,
    prUrl,
    revision,
    environment,
    staleCheck,
    loginUrl,
    account,
    testUrl,
    preconditions,
    blastRadius,
    restoration,
    purpose,
    userOutcome,
    contextFields,
    sections,
    fields,
    steps,
  };
}

function currentIsoTime() {
  const candidate = process.env.FM_MANUAL_VERIFY_NOW || new Date().toISOString();
  const parsed = new Date(candidate);
  if (Number.isNaN(parsed.valueOf()) || parsed.toISOString() !== candidate) {
    throw new InputError([{ path: "FM_MANUAL_VERIFY_NOW", message: "must be an exact ISO-8601 UTC timestamp" }]);
  }
  return candidate;
}

function html(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function jsonForScript(value) {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

function identityFor(spec, generatedAt) {
  return {
    artifactId: spec.taskId,
    revision: spec.revision,
    generatedAt,
    draftKey: `fm-manual-verification:draft:v1:${spec.taskId}:${spec.revision}`,
    queueKey: `fm-manual-verification:${spec.taskId}:${spec.revision}`,
  };
}

function renderLink(label, url) {
  if (!url) return "";
  return `<a href="${html(url)}" rel="noreferrer">${html(label)}</a>`;
}

function renderField(field) {
  const id = `context-${field.id}`;
  const required = field.required ? " required" : "";
  const requiredText = field.required ? `<span class="required" aria-hidden="true"> required</span>` : "";
  let control;
  if (field.type === "textarea") {
    control = `<textarea id="${id}" data-context-id="${html(field.id)}" rows="3"${required}></textarea>`;
  } else if (field.type === "select") {
    const options = field.options
      .map((option) => `<option value="${html(option.value)}">${html(option.label)}</option>`)
      .join("");
    control = `<select id="${id}" data-context-id="${html(field.id)}"${required}><option value="">Choose one</option>${options}</select>`;
  } else {
    control = `<input id="${id}" data-context-id="${html(field.id)}" type="text"${required}>`;
  }
  return `<div class="field"><label for="${id}">${html(field.label)}${requiredText}</label>${control}${field.help ? `<p class="help">${html(field.help)}</p>` : ""}</div>`;
}

function renderStep(step, index) {
  const number = index + 1;
  return `<article class="step-card" data-step-id="${html(step.id)}">
    <div class="step-number" aria-hidden="true">${number}</div>
    <div class="step-content">
      <h3>${html(step.title)}</h3>
      <dl class="behavior-pair">
        <div><dt>Setup</dt><dd>${html(step.setup)}</dd></div>
        <div><dt>Action</dt><dd>${html(step.action)}</dd></div>
        <div class="expected"><dt>Expected behavior</dt><dd>${html(step.expected)}</dd></div>
      </dl>
      <div class="step-fields">
        <div class="field"><label for="step-${number}-status">Result <span class="required" aria-hidden="true">required</span></label>
          <select id="step-${number}-status" data-step-status required>
            <option value="">Choose one</option><option value="PASS">Pass</option><option value="FAIL">Fail</option><option value="BLOCKED">Blocked</option><option value="NOT_RUN">Not Run</option>
          </select>
        </div>
        <div class="field"><label for="step-${number}-actual">Actual behavior</label><textarea id="step-${number}-actual" data-step-actual rows="3" placeholder="State exactly what happened. Fail and Blocked results require this field."></textarea></div>
        <div class="field"><label for="step-${number}-notes">Notes</label><textarea id="step-${number}-notes" data-step-notes rows="2" placeholder="Add setup details, repeat attempts, or limitations."></textarea></div>
      </div>
    </div>
  </article>`;
}

function selectOptions(options) {
  return options.map(([value, label]) => `<option value="${value}">${label}</option>`).join("");
}

function findContradictions(config, answers) {
  const conflicts = [];
  if (answers.overall !== "PASS") return conflicts;
  for (const [index, step] of (answers.steps || []).entries()) {
    if (step.status && step.status !== "PASS") {
      const title = config.steps[index]?.title || step.id || `Step ${index + 1}`;
      conflicts.push(`${title}: ${step.status}`);
    }
  }
  if (answers.consoleHealth === "FAIL" || answers.consoleHealth === "NOT_CHECKED") {
    conflicts.push(`Console health: ${answers.consoleHealth}`);
  }
  if (answers.networkHealth === "FAIL" || answers.networkHealth === "NOT_CHECKED") {
    conflicts.push(`Network health: ${answers.networkHealth}`);
  }
  if (["PENDING", "FAILED", "NOT_RUN"].includes(answers.restorationResult)) {
    conflicts.push(`Restoration result: ${answers.restorationResult}`);
  }
  return conflicts;
}

function validateAnswers(config, answers) {
  const errors = [];
  const add = (path, message) => errors.push({ path, message });
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) {
    return { errors: [{ path: "answers", message: "must be an object" }], conflicts: [] };
  }
  const context = answers.context && typeof answers.context === "object" && !Array.isArray(answers.context)
    ? answers.context
    : {};
  for (const field of config.fields) {
    const value = context[field.id];
    if (field.required && (typeof value !== "string" || value.trim() === "")) {
      add(`context.${field.id}`, "is required");
    }
    if (value !== undefined && typeof value !== "string") add(`context.${field.id}`, "must be a string");
    if (field.type === "select" && typeof value === "string" && value !== "" && !field.options.some((option) => option.value === value)) {
      add(`context.${field.id}`, "must match one configured option");
    }
  }
  if (!Array.isArray(answers.steps) || answers.steps.length !== config.steps.length) {
    add("steps", `must contain exactly ${config.steps.length} step results`);
  } else {
    answers.steps.forEach((step, index) => {
      const expected = config.steps[index];
      const path = `steps[${index}]`;
      if (!step || typeof step !== "object" || Array.isArray(step)) {
        add(path, "must be an object");
        return;
      }
      if (step.id !== expected.id) add(`${path}.id`, `must equal ${expected.id}`);
      if (!STEP_STATUSES.has(step.status)) add(`${path}.status`, "must be PASS, FAIL, BLOCKED, or NOT_RUN");
      if (typeof step.actual !== "string") add(`${path}.actual`, "must be a string");
      if (typeof step.notes !== "string") add(`${path}.notes`, "must be a string");
      if ((step.status === "FAIL" || step.status === "BLOCKED") && (!step.actual || step.actual.trim() === "")) {
        add(`${path}.actual`, "is required for Fail or Blocked results");
      }
    });
  }
  if (!REPEATABILITY_VALUES.has(answers.repeatability)) add("repeatability", "must be a supported repeatability value");
  if (!IMPACT_VALUES.has(answers.acceptanceImpact)) add("acceptanceImpact", "must be a supported acceptance impact");
  if (typeof answers.evidenceLinks !== "string") add("evidenceLinks", "must be a string");
  if (!HEALTH_VALUES.has(answers.consoleHealth)) add("consoleHealth", "must be PASS, FAIL, NOT_CHECKED, or NOT_APPLICABLE");
  if (typeof answers.consoleNotes !== "string") add("consoleNotes", "must be a string");
  if (!HEALTH_VALUES.has(answers.networkHealth)) add("networkHealth", "must be PASS, FAIL, NOT_CHECKED, or NOT_APPLICABLE");
  if (typeof answers.networkNotes !== "string") add("networkNotes", "must be a string");
  if (typeof answers.dataSideEffects !== "string" || answers.dataSideEffects.trim() === "") add("dataSideEffects", "is required; enter None if there were no side effects");
  if (!RESTORATION_VALUES.has(answers.restorationResult)) add("restorationResult", "must be a supported restoration result");
  if (typeof answers.restorationNotes !== "string") add("restorationNotes", "must be a string");
  if (typeof answers.unverifiedItems !== "string" || answers.unverifiedItems.trim() === "") add("unverifiedItems", "is required; enter None if everything was verified");
  if (typeof answers.observations !== "string") add("observations", "must be a string");
  if (!OVERALL_VALUES.has(answers.overall)) add("overall", "must be PASS, FAIL, BLOCKED, or PARTIAL");
  if (typeof answers.contradictionConfirmed !== "boolean") add("contradictionConfirmed", "must be true or false");
  if (typeof answers.contradictionReason !== "string") add("contradictionReason", "must be a string");
  const conflicts = findContradictions(config, answers);
  if (conflicts.length && answers.contradictionConfirmed !== true) {
    add("contradictionConfirmed", "must be visibly confirmed because overall PASS conflicts with unresolved verification items");
  }
  if (conflicts.length && (!answers.contradictionReason || answers.contradictionReason.trim() === "")) {
    add("contradictionReason", "is required when confirming a contradictory overall PASS");
  }
  return { errors, conflicts };
}

function buildSubmission(config, answers, submittedAt) {
  const validation = validateAnswers(config, answers);
  if (validation.errors.length) {
    const error = new Error("manual-verification answers are incomplete or contradictory");
    error.validationErrors = validation.errors;
    throw error;
  }
  const contextSummary = config.fields
    .filter((field) => answers.context[field.id])
    .map((field) => `- ${field.label}: ${answers.context[field.id]}`);
  const stepSummary = answers.steps.map((step, index) =>
    `${index + 1}. ${step.status} - ${config.steps[index].title}\n   Actual: ${step.actual || "Not recorded"}\n   Notes: ${step.notes || "None"}`,
  );
  const summary = [
    `Manual verification ${answers.overall}: ${config.project}`,
    `Issue: ${config.issue}`,
    `Exact revision or environment identity: ${config.revision}`,
    `Environment: ${config.environment}`,
    "Context:",
    ...(contextSummary.length ? contextSummary : ["- No additional context fields"]),
    "Steps:",
    ...stepSummary,
    `Repeatability: ${answers.repeatability}`,
    `Acceptance impact: ${answers.acceptanceImpact}`,
    `Evidence: ${answers.evidenceLinks || "None"}`,
    `Console health: ${answers.consoleHealth} - ${answers.consoleNotes || "No notes"}`,
    `Network health: ${answers.networkHealth} - ${answers.networkNotes || "No notes"}`,
    `Data side effects: ${answers.dataSideEffects}`,
    `Restoration: ${answers.restorationResult} - ${answers.restorationNotes || "No notes"}`,
    `Unverified items: ${answers.unverifiedItems}`,
    `Observations: ${answers.observations || "None"}`,
    validation.conflicts.length
      ? `Contradiction confirmation: ${answers.contradictionReason}`
      : "Contradiction confirmation: not needed",
  ].join("\n");
  const evidenceLinks = answers.evidenceLinks
    .split(/\r?\n/)
    .map((item) => item.trim())
    .filter(Boolean);
  return {
    summary,
    options: {
      tag: "manual-verification",
      text: `${config.project} manual verification ${answers.overall} at ${config.revision}`,
      queueKey: config.queueKey,
      data: {
        kind: "manual-verification",
        schemaVersion: config.schemaVersion,
        artifactId: config.artifactId,
        verificationType: config.verificationType,
        project: config.project,
        issue: config.issue,
        issueUrl: config.issueUrl,
        prUrl: config.prUrl,
        revision: config.revision,
        environment: config.environment,
        generatedAt: config.generatedAt,
        submittedAt,
        overall: answers.overall,
        context: { ...answers.context },
        steps: answers.steps.map((step, index) => ({
          number: index + 1,
          id: config.steps[index].id,
          title: config.steps[index].title,
          status: step.status,
          actual: step.actual,
          notes: step.notes,
        })),
        repeatability: answers.repeatability,
        acceptanceImpact: answers.acceptanceImpact,
        evidenceLinks,
        health: {
          console: { result: answers.consoleHealth, notes: answers.consoleNotes },
          network: { result: answers.networkHealth, notes: answers.networkNotes },
        },
        dataSideEffects: answers.dataSideEffects,
        restoration: { result: answers.restorationResult, notes: answers.restorationNotes },
        unverifiedItems: answers.unverifiedItems,
        observations: answers.observations,
        contradiction: {
          confirmed: answers.contradictionConfirmed,
          reason: answers.contradictionReason,
          conflicts: validation.conflicts,
        },
      },
    },
  };
}

function renderArtifact(spec, identity) {
  const config = { ...spec, ...identity };
  const preconditions = spec.preconditions.map((item) => `<li>${html(item)}</li>`).join("");
  const contextSection = spec.contextFields.length
    ? `<section class="card"><div class="section-heading"><span class="section-kicker">Review context</span><h2>Record the exact test state</h2><p>Use product-visible terms. Do not infer a camera, mode, dataset, client, or environment state that you did not observe.</p></div><div class="field-grid">${spec.contextFields.map(renderField).join("")}</div></section>`
    : "";
  const customSections = spec.sections
    .map((section) => `<section class="card"><div class="section-heading"><span class="section-kicker">Configured context</span><h2>${html(section.title)}</h2>${section.description ? `<p>${html(section.description)}</p>` : ""}</div><div class="field-grid">${section.fields.map(renderField).join("")}</div></section>`)
    .join("");
  const issueLink = spec.issueUrl ? renderLink(spec.issue, spec.issueUrl) : html(spec.issue);
  const prRow = spec.prUrl
    ? `<div><dt>Pull request</dt><dd>${renderLink(spec.prUrl, spec.prUrl)}</dd></div>`
    : `<div><dt>Pull request</dt><dd>Not applicable</dd></div>`;
  const steps = spec.steps.map(renderStep).join("");
  const repeatabilityOptions = selectOptions([
    ["EVERY_TIME", "Every attempt"],
    ["SOMETIMES", "Intermittent"],
    ["ONCE", "Observed once"],
    ["COULD_NOT_REPEAT", "Could not repeat"],
    ["NOT_APPLICABLE", "Not applicable"],
    ["NOT_RUN", "Not run"],
  ]);
  const impactOptions = selectOptions([
    ["BLOCKING", "Blocking acceptance impact"],
    ["NON_BLOCKING", "Non-blocking acceptance impact"],
    ["UNKNOWN", "Impact needs assessment"],
    ["NOT_APPLICABLE", "Not applicable"],
  ]);
  const healthOptions = selectOptions([
    ["PASS", "Pass - healthy"],
    ["FAIL", "Fail - unhealthy"],
    ["NOT_CHECKED", "Not checked"],
    ["NOT_APPLICABLE", "Not applicable"],
  ]);
  const restorationOptions = selectOptions([
    ["RESTORED", "Restored and verified"],
    ["NOT_NEEDED", "No restoration needed"],
    ["PENDING", "Restoration pending"],
    ["FAILED", "Restoration failed"],
    ["NOT_RUN", "Not run"],
  ]);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>${html(spec.issue)} manual verification</title>
<style>
:root {
  --navy: #102a43;
  --navy-2: #243b53;
  --blue: #0b5cad;
  --blue-dark: #084782;
  --sky: #e8f4ff;
  --paper: #ffffff;
  --canvas: #edf3f8;
  --ink: #102a43;
  --muted: #486581;
  --line: #bcccdc;
  --green: #146c43;
  --green-soft: #e5f6ed;
  --amber: #7a4800;
  --amber-soft: #fff3cd;
  --red: #9b1c31;
  --red-soft: #fde8ec;
  --focus: #ffbf47;
  --shadow: 0 16px 36px rgba(16, 42, 67, 0.12);
}
*, *::before, *::after { box-sizing: border-box; }
html { background: var(--canvas); }
body {
  margin: 0;
  min-width: 0;
  overflow-x: hidden;
  background: linear-gradient(180deg, var(--navy) 0 19rem, var(--canvas) 19rem 100%);
  color: var(--ink);
  font: 16px/1.55 Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
a { color: var(--blue-dark); font-weight: 700; overflow-wrap: anywhere; }
a:hover { text-decoration-thickness: 2px; }
button, input, select, textarea { font: inherit; }
button, input, select, textarea, a { outline-offset: 3px; }
:focus-visible { outline: 3px solid var(--focus); }
main { width: min(1040px, calc(100% - 2rem)); margin: 0 auto; padding: 2rem 0 5rem; }
main > *, .card > *, .step-content, .field, .meta-grid > div, .field-grid > *, .summary-grid > * { min-width: 0; }
p, h1, h2, h3, li, dd, dt, label, legend, .badge, .status-copy { overflow-wrap: anywhere; }
.hero {
  padding: clamp(1.25rem, 3vw, 2.5rem);
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 1.25rem;
  background: rgba(255, 255, 255, 0.98);
  box-shadow: var(--shadow);
}
.eyebrow, .section-kicker { color: var(--blue-dark); font-size: 0.75rem; font-weight: 900; letter-spacing: 0.09em; text-transform: uppercase; }
h1 { margin: 0.35rem 0 0.75rem; max-width: 22ch; font-size: clamp(2rem, 6vw, 3.5rem); line-height: 1.05; }
h2 { margin: 0.25rem 0 0.5rem; font-size: clamp(1.35rem, 3vw, 1.8rem); line-height: 1.2; }
h3 { margin: 0; font-size: 1.15rem; line-height: 1.3; }
.lede { max-width: 72ch; color: var(--navy-2); font-size: 1.05rem; }
.badges { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-top: 1rem; }
.badge { max-width: 100%; padding: 0.35rem 0.65rem; border-radius: 999px; background: var(--sky); color: var(--navy); font-size: 0.78rem; font-weight: 800; }
.stale-warning { margin-top: 1.25rem; padding: 1rem; border: 2px solid #d39120; border-radius: 0.8rem; background: var(--amber-soft); color: #4f2f00; }
.stale-warning strong { display: block; margin-bottom: 0.25rem; font-size: 1rem; }
.card { margin-top: 1rem; padding: clamp(1rem, 2.5vw, 1.6rem); border: 1px solid var(--line); border-radius: 1rem; background: var(--paper); box-shadow: 0 8px 24px rgba(16, 42, 67, 0.07); }
.section-heading { margin-bottom: 1rem; }
.section-heading p { margin: 0.3rem 0 0; color: var(--muted); }
.meta-grid, .summary-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.8rem 1.25rem; }
.meta-grid div, .summary-grid article { padding: 0.8rem; border-radius: 0.7rem; background: #f5f8fb; }
.meta-grid > div:nth-child(5) { grid-column: 1 / -1; }
dt { color: var(--muted); font-size: 0.76rem; font-weight: 900; letter-spacing: 0.04em; text-transform: uppercase; }
dd { margin: 0.2rem 0 0; }
.outcome { padding: 1rem; border-left: 5px solid var(--blue); background: var(--sky); }
.preconditions { margin: 0.5rem 0 0; padding-left: 1.25rem; }
.preconditions li + li { margin-top: 0.35rem; }
.field-grid, .step-fields { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; }
.field { display: grid; align-content: start; gap: 0.35rem; }
.field label, fieldset legend { color: var(--navy); font-weight: 850; }
.required { color: var(--red); font-size: 0.72rem; text-transform: uppercase; }
.help { margin: 0; color: var(--muted); font-size: 0.85rem; }
input[type="text"], select, textarea {
  display: block;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  min-height: 2.75rem;
  padding: 0.7rem 0.75rem;
  border: 2px solid #829ab1;
  border-radius: 0.55rem;
  background: #fff;
  color: var(--ink);
}
textarea { resize: vertical; }
.steps { display: grid; gap: 1rem; }
.step-card { display: grid; grid-template-columns: 2.6rem minmax(0, 1fr); gap: 0.9rem; min-width: 0; padding: 1rem; border: 1px solid var(--line); border-radius: 0.9rem; background: #fbfdff; }
.step-number { display: grid; width: 2.4rem; height: 2.4rem; place-items: center; border-radius: 999px; background: var(--navy); color: #fff; font-weight: 900; }
.behavior-pair { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.65rem; margin: 0.85rem 0 1rem; }
.behavior-pair div { padding: 0.75rem; border: 1px solid #d9e2ec; border-radius: 0.65rem; background: #fff; }
.behavior-pair .expected { grid-column: 1 / -1; border-color: #8fc4f5; background: var(--sky); }
.step-fields .field:nth-child(2), .step-fields .field:nth-child(3) { grid-column: 1 / -1; }
fieldset { min-width: 0; margin: 0; padding: 0; border: 0; }
.radio-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.7rem; }
.radio-option { display: flex; min-width: 0; align-items: flex-start; gap: 0.65rem; min-height: 3rem; padding: 0.8rem; border: 2px solid var(--line); border-radius: 0.7rem; background: #fff; cursor: pointer; }
.radio-option:has(input:checked) { border-color: var(--blue); background: var(--sky); }
.radio-option input { flex: 0 0 auto; width: 1.2rem; height: 1.2rem; margin-top: 0.15rem; }
.health-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; }
.health-card { min-width: 0; padding: 1rem; border: 1px solid var(--line); border-radius: 0.8rem; background: #f8fbfe; }
.health-card .field + .field { margin-top: 0.75rem; }
.contradiction { margin-top: 1rem; padding: 1rem; border: 3px solid var(--red); border-radius: 0.8rem; background: var(--red-soft); color: #65101f; }
.contradiction[hidden] { display: none; }
.confirm-row { display: flex; align-items: flex-start; gap: 0.65rem; margin: 0.8rem 0; font-weight: 850; }
.confirm-row input { flex: 0 0 auto; width: 1.25rem; height: 1.25rem; margin-top: 0.15rem; }
.validation-errors { margin-top: 1rem; padding: 1rem; border: 2px solid var(--red); border-radius: 0.8rem; background: var(--red-soft); color: #65101f; }
.validation-errors[hidden] { display: none; }
.actions { display: flex; flex-wrap: wrap; align-items: center; gap: 0.75rem; margin-top: 1rem; padding: 1rem; border: 1px solid var(--line); border-radius: 0.9rem; background: rgba(255, 255, 255, 0.97); box-shadow: 0 8px 24px rgba(16, 42, 67, 0.12); }
button { min-height: 2.75rem; padding: 0.65rem 1rem; border: 2px solid transparent; border-radius: 0.55rem; font-weight: 900; cursor: pointer; }
.primary { background: var(--blue); color: #fff; }
.primary:hover { background: var(--blue-dark); }
.secondary { border-color: var(--navy); background: #fff; color: var(--navy); }
.status-copy { flex: 1 1 15rem; color: var(--green); font-weight: 800; }
.reset-dialog { width: min(32rem, calc(100% - 2rem)); padding: 0; border: 2px solid var(--navy); border-radius: 0.9rem; color: var(--ink); box-shadow: var(--shadow); }
.reset-dialog::backdrop { background: rgba(16, 42, 67, 0.72); }
.reset-dialog form { padding: 1.25rem; }
.reset-dialog h2 { margin-top: 0; }
.dialog-actions { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 0.75rem; margin-top: 1rem; }
.secret-warning { margin: 0.35rem 0 0; color: var(--red); font-size: 0.83rem; font-weight: 800; }
@media (max-width: 640px) {
  main { width: min(100% - 1rem, 1040px); padding-top: 0.75rem; }
  .hero, .card { border-radius: 0.75rem; }
  .meta-grid, .summary-grid, .field-grid, .step-fields, .behavior-pair, .radio-grid, .health-grid { grid-template-columns: minmax(0, 1fr); }
  .behavior-pair .expected, .step-fields .field:nth-child(2), .step-fields .field:nth-child(3) { grid-column: auto; }
  .step-card { grid-template-columns: minmax(0, 1fr); }
  .actions { position: static; align-items: stretch; }
  .actions button { width: 100%; }
}
</style>
</head>
<body>
<main>
<header class="hero">
  <span class="eyebrow">Structured manual verification</span>
  <h1>${html(spec.issue)}</h1>
  <p class="lede">${html(spec.purpose)}</p>
  <div class="badges"><span class="badge">${html(spec.verificationType)}</span><span class="badge">${html(spec.project)}</span><span class="badge">Generated ${html(identity.generatedAt)}</span></div>
  <div class="stale-warning" role="alert"><strong>STALE REVISION WARNING</strong>Verify the running revision or environment before every pass. The required identity is <code>${html(spec.revision)}</code>. ${html(spec.staleCheck)} Stop and regenerate this artifact if the identity differs.</div>
</header>
<form id="manual-verification" data-lavish-question="${html(spec.taskId)}" novalidate>
<section class="card">
  <div class="section-heading"><span class="section-kicker">Identity and access</span><h2>Verify the target before testing</h2></div>
  <dl class="meta-grid">
    <div><dt>Project</dt><dd>${html(spec.project)}</dd></div>
    <div><dt>Issue</dt><dd>${issueLink}</dd></div>
    ${prRow}
    <div><dt>Exact revision or environment identity</dt><dd><code>${html(spec.revision)}</code></dd></div>
    <div><dt>Environment</dt><dd>${html(spec.environment)}</dd></div>
    <div><dt>Generated time</dt><dd>${html(identity.generatedAt)}</dd></div>
    <div><dt>Login URL</dt><dd>${renderLink(spec.loginUrl, spec.loginUrl)}</dd></div>
    <div><dt>Account identifier</dt><dd>${html(spec.account)}</dd></div>
    <div><dt>Project or test URL</dt><dd>${renderLink(spec.testUrl, spec.testUrl)}</dd></div>
  </dl>
  <p class="secret-warning">Never paste a password, token, cookie, credential, or other secret into this artifact.</p>
</section>
<section class="card">
  <div class="section-heading"><span class="section-kicker">Purpose and safety</span><h2>What success means</h2></div>
  <div class="outcome"><strong>Intended user outcome:</strong> ${html(spec.userOutcome)}</div>
  <div class="summary-grid" style="margin-top: 1rem">
    <article><h3>Preconditions</h3><ul class="preconditions">${preconditions}</ul></article>
    <article><h3>Blast radius</h3><p>${html(spec.blastRadius)}</p></article>
    <article><h3>Restoration expectation</h3><p>${html(spec.restoration)}</p></article>
    <article><h3>Revision check</h3><p>${html(spec.staleCheck)}</p></article>
  </div>
</section>
${contextSection}
${customSections}
<section class="card">
  <div class="section-heading"><span class="section-kicker">Numbered checklist</span><h2>Run and record every step</h2><p>Record the actual behavior even when the expected behavior passes. Use Not Run rather than guessing.</p></div>
  <div class="steps">${steps}</div>
</section>
<section class="card">
  <div class="section-heading"><span class="section-kicker">Cross-check evidence</span><h2>Repeatability, impact, and evidence</h2></div>
  <div class="field-grid">
    <div class="field"><label for="repeatability">Repeatability <span class="required" aria-hidden="true">required</span></label><select id="repeatability" name="repeatability" required><option value="">Choose one</option>${repeatabilityOptions}</select></div>
    <div class="field"><label for="acceptanceImpact">Acceptance impact <span class="required" aria-hidden="true">required</span></label><select id="acceptanceImpact" name="acceptanceImpact" required><option value="">Choose one</option>${impactOptions}</select></div>
    <div class="field" style="grid-column: 1 / -1"><label for="evidenceLinks">Evidence links</label><textarea id="evidenceLinks" name="evidenceLinks" rows="3" placeholder="One screenshot, video, or file URL/path per line."></textarea></div>
  </div>
</section>
<section class="card">
  <div class="section-heading"><span class="section-kicker">System health</span><h2>Console, network, data, and restoration</h2></div>
  <div class="health-grid">
    <article class="health-card"><div class="field"><label for="consoleHealth">Console health <span class="required" aria-hidden="true">required</span></label><select id="consoleHealth" name="consoleHealth" required><option value="">Choose one</option>${healthOptions}</select></div><div class="field"><label for="consoleNotes">Console notes</label><textarea id="consoleNotes" name="consoleNotes" rows="3"></textarea></div></article>
    <article class="health-card"><div class="field"><label for="networkHealth">Network health <span class="required" aria-hidden="true">required</span></label><select id="networkHealth" name="networkHealth" required><option value="">Choose one</option>${healthOptions}</select></div><div class="field"><label for="networkNotes">Network notes</label><textarea id="networkNotes" name="networkNotes" rows="3"></textarea></div></article>
  </div>
  <div class="field-grid" style="margin-top: 1rem">
    <div class="field"><label for="dataSideEffects">Data side effects <span class="required" aria-hidden="true">required</span></label><textarea id="dataSideEffects" name="dataSideEffects" rows="3" required placeholder="Enter None if no side effects occurred."></textarea></div>
    <div class="field"><label for="restorationResult">Restoration result <span class="required" aria-hidden="true">required</span></label><select id="restorationResult" name="restorationResult" required><option value="">Choose one</option>${restorationOptions}</select></div>
    <div class="field"><label for="restorationNotes">Restoration notes</label><textarea id="restorationNotes" name="restorationNotes" rows="3"></textarea></div>
    <div class="field"><label for="unverifiedItems">Unverified items <span class="required" aria-hidden="true">required</span></label><textarea id="unverifiedItems" name="unverifiedItems" rows="3" required placeholder="Enter None if everything was verified."></textarea></div>
    <div class="field" style="grid-column: 1 / -1"><label for="observations">Free-form observations</label><textarea id="observations" name="observations" rows="4"></textarea></div>
  </div>
</section>
<section class="card">
  <div class="section-heading"><span class="section-kicker">Final classification</span><h2>Overall result</h2><p>Choose one explicit result for this exact revision and environment.</p></div>
  <fieldset><legend>Overall result <span class="required" aria-hidden="true">required</span></legend>
    <div class="radio-grid">
      <label class="radio-option"><input type="radio" name="overall" value="PASS" required><span><strong>PASS</strong><br>Acceptance behavior is verified.</span></label>
      <label class="radio-option"><input type="radio" name="overall" value="FAIL"><span><strong>FAIL</strong><br>A defect or acceptance failure was observed.</span></label>
      <label class="radio-option"><input type="radio" name="overall" value="BLOCKED"><span><strong>BLOCKED</strong><br>A prerequisite prevented a valid verdict.</span></label>
      <label class="radio-option"><input type="radio" name="overall" value="PARTIAL"><span><strong>PARTIAL</strong><br>Some items remain unverified or mixed.</span></label>
    </div>
  </fieldset>
  <div class="contradiction" id="contradiction" role="alert" hidden>
    <h3>PASS conflicts with unresolved verification items</h3>
    <p id="contradiction-list"></p>
    <label class="confirm-row"><input id="contradictionConfirmed" name="contradictionConfirmed" type="checkbox"><span>I deliberately confirm this overall PASS despite the unresolved items listed above.</span></label>
    <div class="field"><label for="contradictionReason">Confirmation reason</label><textarea id="contradictionReason" name="contradictionReason" rows="3" placeholder="Explain why PASS is still correct for this acceptance decision."></textarea></div>
  </div>
  <div class="validation-errors" id="validation-errors" role="alert" tabindex="-1" hidden><strong>Complete or correct these fields:</strong><ul id="validation-list"></ul></div>
</section>
<div class="actions">
  <button class="primary" type="submit">Queue complete verification</button>
  <button class="secondary" id="reset-draft" type="button">Reset saved draft</button>
  <span class="status-copy" id="draft-state" role="status" aria-live="polite">No local draft saved for this revision.</span>
</div>
</form>
<dialog class="reset-dialog" id="reset-dialog" aria-labelledby="reset-title">
  <form method="dialog">
    <h2 id="reset-title">Reset this revision's saved draft?</h2>
    <p>This clears every answer saved for this artifact and exact revision. It does not affect drafts for another revision.</p>
    <div class="dialog-actions">
      <button class="secondary" value="cancel" type="submit">Keep draft</button>
      <button class="primary" value="confirm" type="submit">Reset all answers</button>
    </div>
  </form>
</dialog>
</main>
<script id="fm-manual-verification-config" type="application/json">${jsonForScript(config)}</script>
<script>
(() => {
  "use strict";
  const config = JSON.parse(document.getElementById("fm-manual-verification-config").textContent);
  const STEP_STATUSES = new Set(["PASS", "FAIL", "BLOCKED", "NOT_RUN"]);
  const REPEATABILITY_VALUES = new Set(["EVERY_TIME", "SOMETIMES", "ONCE", "COULD_NOT_REPEAT", "NOT_APPLICABLE", "NOT_RUN"]);
  const IMPACT_VALUES = new Set(["BLOCKING", "NON_BLOCKING", "UNKNOWN", "NOT_APPLICABLE"]);
  const HEALTH_VALUES = new Set(["PASS", "FAIL", "NOT_CHECKED", "NOT_APPLICABLE"]);
  const RESTORATION_VALUES = new Set(["RESTORED", "NOT_NEEDED", "PENDING", "FAILED", "NOT_RUN"]);
  const OVERALL_VALUES = new Set(["PASS", "FAIL", "BLOCKED", "PARTIAL"]);
  const findContradictions = ${findContradictions.toString()};
  const validateAnswers = ${validateAnswers.toString()};
  const buildSubmission = ${buildSubmission.toString()};
  const form = document.getElementById("manual-verification");
  const draftState = document.getElementById("draft-state");
  const contradiction = document.getElementById("contradiction");
  const contradictionList = document.getElementById("contradiction-list");
  const contradictionConfirmed = document.getElementById("contradictionConfirmed");
  const contradictionReason = document.getElementById("contradictionReason");
  const validationBox = document.getElementById("validation-errors");
  const validationList = document.getElementById("validation-list");
  let saveTimer;

  function namedValue(name) {
    const control = form.elements.namedItem(name);
    if (!control) return "";
    if (typeof RadioNodeList !== "undefined" && control instanceof RadioNodeList) return control.value || "";
    if (control.type === "checkbox") return control.checked;
    return control.value || "";
  }

  function collectAnswers() {
    const context = {};
    for (const field of config.fields) {
      const control = form.querySelector('[data-context-id="' + field.id + '"]');
      context[field.id] = control ? control.value : "";
    }
    const steps = config.steps.map((step) => {
      const card = form.querySelector('[data-step-id="' + step.id + '"]');
      return {
        id: step.id,
        status: card.querySelector("[data-step-status]").value,
        actual: card.querySelector("[data-step-actual]").value,
        notes: card.querySelector("[data-step-notes]").value,
      };
    });
    return {
      context,
      steps,
      repeatability: namedValue("repeatability"),
      acceptanceImpact: namedValue("acceptanceImpact"),
      evidenceLinks: namedValue("evidenceLinks"),
      consoleHealth: namedValue("consoleHealth"),
      consoleNotes: namedValue("consoleNotes"),
      networkHealth: namedValue("networkHealth"),
      networkNotes: namedValue("networkNotes"),
      dataSideEffects: namedValue("dataSideEffects"),
      restorationResult: namedValue("restorationResult"),
      restorationNotes: namedValue("restorationNotes"),
      unverifiedItems: namedValue("unverifiedItems"),
      observations: namedValue("observations"),
      overall: namedValue("overall"),
      contradictionConfirmed: Boolean(namedValue("contradictionConfirmed")),
      contradictionReason: namedValue("contradictionReason"),
    };
  }

  function setNamedValue(name, value) {
    const control = form.elements.namedItem(name);
    if (!control) return;
    if (typeof RadioNodeList !== "undefined" && control instanceof RadioNodeList) {
      for (const item of control) item.checked = item.value === value;
    } else if (control.type === "checkbox") {
      control.checked = value === true;
    } else {
      control.value = typeof value === "string" ? value : "";
    }
  }

  function applyAnswers(answers) {
    if (!answers || typeof answers !== "object") return;
    for (const field of config.fields) {
      const control = form.querySelector('[data-context-id="' + field.id + '"]');
      if (control && typeof answers.context?.[field.id] === "string") control.value = answers.context[field.id];
    }
    if (Array.isArray(answers.steps)) {
      for (const stepAnswer of answers.steps) {
        const card = config.steps.some((step) => step.id === stepAnswer.id)
          ? form.querySelector('[data-step-id="' + stepAnswer.id + '"]')
          : null;
        if (!card) continue;
        card.querySelector("[data-step-status]").value = typeof stepAnswer.status === "string" ? stepAnswer.status : "";
        card.querySelector("[data-step-actual]").value = typeof stepAnswer.actual === "string" ? stepAnswer.actual : "";
        card.querySelector("[data-step-notes]").value = typeof stepAnswer.notes === "string" ? stepAnswer.notes : "";
      }
    }
    for (const name of [
      "repeatability", "acceptanceImpact", "evidenceLinks", "consoleHealth", "consoleNotes",
      "networkHealth", "networkNotes", "dataSideEffects", "restorationResult", "restorationNotes",
      "unverifiedItems", "observations", "overall", "contradictionConfirmed", "contradictionReason",
    ]) setNamedValue(name, answers[name]);
  }

  function updateContradiction() {
    const conflicts = findContradictions(config, collectAnswers());
    const visible = conflicts.length > 0;
    contradiction.hidden = !visible;
    contradictionConfirmed.required = visible;
    contradictionReason.required = visible;
    contradictionList.textContent = visible ? conflicts.join("; ") : "";
  }

  function showErrors(errors) {
    validationList.replaceChildren();
    for (const item of errors) {
      const li = document.createElement("li");
      li.textContent = item.path + ": " + item.message;
      validationList.append(li);
    }
    validationBox.hidden = errors.length === 0;
    if (errors.length) validationBox.focus();
  }

  function windowNameEnvelope() {
    try {
      const parsed = JSON.parse(window.name || "null");
      if (parsed && parsed.marker === "fm-manual-verification-drafts-v1" && parsed.drafts && typeof parsed.drafts === "object") {
        return parsed;
      }
    } catch {}
    return { marker: "fm-manual-verification-drafts-v1", previous: window.name || "", drafts: {} };
  }

  function readDraft() {
    try {
      return localStorage.getItem(config.draftKey);
    } catch {
      return windowNameEnvelope().drafts[config.draftKey] || null;
    }
  }

  function writeDraft(value) {
    try {
      localStorage.setItem(config.draftKey, value);
      return;
    } catch {}
    const envelope = windowNameEnvelope();
    envelope.drafts[config.draftKey] = value;
    window.name = JSON.stringify(envelope);
  }

  function clearDraft() {
    try {
      localStorage.removeItem(config.draftKey);
      return;
    } catch {}
    const envelope = windowNameEnvelope();
    delete envelope.drafts[config.draftKey];
    window.name = Object.keys(envelope.drafts).length ? JSON.stringify(envelope) : envelope.previous;
  }

  function saveDraft(message = "Draft saved locally for this artifact and revision.") {
    try {
      writeDraft(JSON.stringify({ answers: collectAnswers(), savedAt: new Date().toISOString() }));
      draftState.textContent = message;
    } catch {
      draftState.textContent = "Draft could not be saved in this browser.";
    }
  }

  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => saveDraft(), 120);
    updateContradiction();
    showErrors([]);
  }

  try {
    const saved = JSON.parse(readDraft() || "null");
    if (saved?.answers) {
      applyAnswers(saved.answers);
      draftState.textContent = "Draft restored for this artifact and exact revision.";
    }
  } catch {
    draftState.textContent = "Saved draft was unreadable and was not restored.";
  }
  updateContradiction();

  form.addEventListener("input", scheduleSave);
  form.addEventListener("change", scheduleSave);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    updateContradiction();
    if (!form.reportValidity()) {
      draftState.textContent = "Draft saved, but required fields still need attention.";
      saveDraft(draftState.textContent);
      return;
    }
    const answers = collectAnswers();
    let submission;
    try {
      submission = buildSubmission(config, answers, new Date().toISOString());
    } catch (error) {
      const errors = Array.isArray(error.validationErrors)
        ? error.validationErrors
        : [{ path: "submission", message: "could not build the structured result" }];
      showErrors(errors);
      saveDraft("Draft saved, but the result is incomplete or contradictory.");
      return;
    }
    if (!window.lavish || typeof window.lavish.queuePrompt !== "function") {
      showErrors([{ path: "Lavish", message: "open this artifact through lavish-axi before submitting" }]);
      saveDraft("Draft saved. Open through Lavish to submit it.");
      return;
    }
    window.lavish.queuePrompt(submission.summary, { ...submission.options, element: form });
    saveDraft("Submitted to the Lavish queue. Use Send to Agent to deliver this complete result.");
  });

  const resetDialog = document.getElementById("reset-dialog");
  document.getElementById("reset-draft").addEventListener("click", () => {
    resetDialog.showModal();
  });
  resetDialog.addEventListener("close", () => {
    if (resetDialog.returnValue !== "confirm") return;
    clearDraft();
    form.reset();
    updateContradiction();
    showErrors([]);
    draftState.textContent = "Draft reset. No local answers remain for this revision.";
  });

  window.fmManualVerification = Object.freeze({ findContradictions, validateAnswers, buildSubmission });
})();
</script>
</body>
</html>
`;
}

function homeRoot() {
  const configured = process.env.FM_HOME || ROOT;
  if (!isAbsolute(configured)) {
    throw new InputError([{ path: "FM_HOME", message: "must be an absolute path" }]);
  }
  if (!existsSync(configured) || !lstatSync(configured).isDirectory() || lstatSync(configured).isSymbolicLink()) {
    throw new InputError([{ path: "FM_HOME", message: "must name an existing non-symlink directory" }]);
  }
  return realpathSync(configured);
}

function privateArtifactPath(spec) {
  const home = homeRoot();
  const dataRoot = join(home, "data");
  if (existsSync(dataRoot)) {
    const stat = lstatSync(dataRoot);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new InputError([{ path: "FM_HOME/data", message: "must be a non-symlink directory" }]);
    }
  } else {
    mkdirSync(dataRoot, { mode: 0o700 });
  }
  const realData = realpathSync(dataRoot);
  if (dirname(realData) !== home) {
    throw new InputError([{ path: "FM_HOME/data", message: "resolves outside FM_HOME" }]);
  }
  const taskDir = join(realData, spec.taskId);
  if (existsSync(taskDir)) {
    const stat = lstatSync(taskDir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new InputError([{ path: "taskId", message: "target task directory must not be a symlink or non-directory" }]);
    }
  } else {
    mkdirSync(taskDir, { mode: 0o700 });
  }
  chmodSync(taskDir, 0o700);
  if (dirname(realpathSync(taskDir)) !== realData) {
    throw new InputError([{ path: "taskId", message: "target task directory resolves outside FM_HOME/data" }]);
  }
  const artifact = join(taskDir, ARTIFACT_FILENAME);
  if (existsSync(artifact)) {
    const stat = lstatSync(artifact);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new InputError([{ path: "artifact", message: "existing output must be a regular non-symlink file" }]);
    }
  }
  return artifact;
}

function atomicPrivateWrite(path, content) {
  const temp = join(dirname(path), `.${ARTIFACT_FILENAME}.${process.pid}.${Date.now()}.tmp`);
  let fd;
  try {
    fd = openSync(temp, "wx", 0o600);
    writeFileSync(fd, content, "utf8");
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    chmodSync(temp, 0o600);
    renameSync(temp, path);
    chmodSync(path, 0o600);
  } catch (error) {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
    try { unlinkSync(temp); } catch {}
    throw error;
  }
}

function generatedConfigFromArtifact(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    throw new InputError([{ path: "artifact", message: `cannot read ${path}: ${error.message}` }]);
  }
  const match = raw.match(/<script id="fm-manual-verification-config" type="application\/json">([\s\S]*?)<\/script>/);
  if (!match) {
    throw new InputError([{ path: "artifact", message: "does not contain a Firstmate manual-verification configuration" }]);
  }
  let config;
  try {
    config = JSON.parse(match[1]);
  } catch (error) {
    throw new InputError([{ path: "artifact", message: `contains invalid generated configuration: ${error.message}` }]);
  }
  if (config.schemaVersion !== SCHEMA_VERSION || typeof config.queueKey !== "string" || !Array.isArray(config.steps) || !Array.isArray(config.fields)) {
    throw new InputError([{ path: "artifact", message: "contains an unsupported or incomplete generated configuration" }]);
  }
  return config;
}

function generate(specPath) {
  const spec = validateSpec(readJson(specPath, "spec"));
  const generatedAt = currentIsoTime();
  const identity = identityFor(spec, generatedAt);
  const artifact = privateArtifactPath(spec);
  atomicPrivateWrite(artifact, renderArtifact(spec, identity));
  const output = {
    artifact,
    ...identity,
    handoff: {
      requiredOrder: ["create-session-without-opening", "arm-feedback-return", "present-artifact"],
      commands: [
        { action: "create-session-without-opening", argv: ["lavish-axi", artifact, "--no-open"] },
        { action: "arm-feedback-return", argv: [join(ROOT, "bin", "fm-procevent-lavish.sh"), "arm", artifact] },
        { action: "present-artifact", argv: ["lavish-axi", artifact] },
      ],
      feedbackOwner: join(ROOT, ".agents", "skills", "process-event-sources", "SKILL.md"),
    },
  };
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
}

function submission(artifactPath, answersPath) {
  const config = generatedConfigFromArtifact(artifactPath);
  const answers = readJson(answersPath, "answers");
  let result;
  try {
    result = buildSubmission(config, answers, currentIsoTime());
  } catch (error) {
    if (Array.isArray(error.validationErrors)) throw new InputError(error.validationErrors);
    throw error;
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  if (!command || command === "-h" || command === "--help" || command === "help") {
    usage();
    return;
  }
  if (command === "generate" && args.length === 1) {
    generate(args[0]);
    return;
  }
  if (command === "submission" && args.length === 2) {
    submission(args[0], args[1]);
    return;
  }
  usage(process.stderr);
  process.exitCode = 2;
}

try {
  main();
} catch (error) {
  if (error instanceof InputError) {
    process.stderr.write("fm-manual-verify: invalid input\n");
    for (const item of error.errors) process.stderr.write(`- ${item.path}: ${item.message}\n`);
    process.exitCode = 2;
  } else {
    process.stderr.write(`fm-manual-verify: ${error.message}\n`);
    process.exitCode = 1;
  }
}
