/**
 * Environment configuration, loaded once at boot and validated with Zod.
 *
 * Everything the server needs comes from env (12-factor). We fail fast and loud
 * at startup if something required is missing or malformed, rather than crashing
 * mid-session. `PINCH_MOCK` decouples the whole server from the SDK + API key so
 * the system is testable end-to-end without credentials.
 */
import { config as loadDotenv } from "dotenv";
import { z } from "zod";

loadDotenv();

/** Coerce "1"/"true"/"yes"/"on" → true, everything else → false. */
const boolFlag = z
  .string()
  .optional()
  .transform((v) => {
    if (!v) return false;
    return ["1", "true", "yes", "on"].includes(v.trim().toLowerCase());
  });

/** Split a comma list into trimmed, non-empty entries. */
const csv = z
  .string()
  .optional()
  .transform((v) =>
    (v ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0),
  );

const EnvSchema = z
  .object({
    PORT: z
      .string()
      .optional()
      .transform((v) => (v ? Number(v) : 8787))
      .pipe(z.number().int().positive()),
    PINCH_TOKEN: z.string().min(1, "PINCH_TOKEN is required"),
    PINCH_MOCK: boolFlag,
    // Load the user's claude.ai cloud connectors (Gmail, Drive, …) into every agent session by
    // opting the SDK into user settings (settingSources: ['user']). This is what gives the watch
    // the same connectors as the CLI terminal. Default ON; set PINCH_LOAD_CONNECTORS=0 to disable
    // (the kill-switch) if loading user settings drags in unwanted hooks/skills that bloat a turn.
    PINCH_LOAD_CONNECTORS: z
      .string()
      .optional()
      .transform((v) =>
        v === undefined ? true : ["1", "true", "yes", "on"].includes(v.trim().toLowerCase()),
      ),
    // Explicit allowlist of repo roots (each becomes one selectable project).
    PINCH_PROJECTS: csv,
    // Parent dir(s) to SCAN: every immediate child folder becomes a selectable
    // project, recomputed each time the watch opens the picker. This is what makes
    // "point the server at ~/Desktop/projects and see everything" work.
    PINCH_PROJECT_ROOTS: csv,
    PINCH_MODEL: z.string().default("claude-opus-4-8"),
    // How the Agent SDK authenticates to Anthropic:
    //  - "subscription" (default): use the Claude Code login already on this Mac
    //    (your Claude Max plan, stored in the keychain). No API key needed.
    //  - "apikey": use ANTHROPIC_API_KEY.
    PINCH_AUTH: z.enum(["subscription", "apikey"]).default("subscription"),
    ANTHROPIC_API_KEY: z
      .string()
      .optional()
      .transform((v) => (v && v.trim().length > 0 ? v.trim() : undefined)),
    LOG_LEVEL: z
      .enum(["trace", "debug", "info", "warn", "error", "fatal"])
      .default("info"),
    NODE_ENV: z.string().default("development"),
  })
  .superRefine((env, ctx) => {
    if (!env.PINCH_MOCK && env.PINCH_AUTH === "apikey" && !env.ANTHROPIC_API_KEY) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["ANTHROPIC_API_KEY"],
        message:
          "ANTHROPIC_API_KEY is required when PINCH_AUTH=apikey. " +
          "Leave PINCH_AUTH unset (or =subscription) to use your Claude Code login instead.",
      });
    }
    if (
      !env.PINCH_MOCK &&
      env.PINCH_PROJECTS.length === 0 &&
      env.PINCH_PROJECT_ROOTS.length === 0
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["PINCH_PROJECTS"],
        message:
          "Set PINCH_PROJECT_ROOTS (a parent dir to scan, e.g. ~/Desktop/projects) " +
          "and/or PINCH_PROJECTS (explicit absolute repo paths) — at least one is required",
      });
    }
  });

function buildConfig() {
  const parsed = EnvSchema.safeParse(process.env);
  if (!parsed.success) {
    // No logger yet — fail fast on stderr with a readable message.
    const issues = parsed.error.issues
      .map((i) => `  - ${i.path.join(".") || "(root)"}: ${i.message}`)
      .join("\n");
    process.stderr.write(`Invalid environment configuration:\n${issues}\n`);
    process.exit(1);
  }
  const env = parsed.data;

  // In subscription mode, make sure no stray ANTHROPIC_API_KEY (e.g. an empty
  // `ANTHROPIC_API_KEY=` line in .env, or one exported in the shell) leaks to the
  // SDK — an empty/forced key would override the Claude Code keychain login.
  if (env.PINCH_AUTH === "subscription") {
    delete process.env.ANTHROPIC_API_KEY;
  }

  return {
    port: env.PORT,
    token: env.PINCH_TOKEN,
    mock: env.PINCH_MOCK,
    loadConnectors: env.PINCH_LOAD_CONNECTORS,
    projects: env.PINCH_PROJECTS,
    projectRoots: env.PINCH_PROJECT_ROOTS,
    model: env.PINCH_MODEL,
    authMode: env.PINCH_AUTH,
    anthropicApiKey: env.PINCH_AUTH === "apikey" ? env.ANTHROPIC_API_KEY : undefined,
    logLevel: env.LOG_LEVEL,
    isDev: env.NODE_ENV !== "production",
  } as const;
}

export type Config = ReturnType<typeof buildConfig>;
export const config: Config = buildConfig();
