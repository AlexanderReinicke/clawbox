import { CommandError } from "./exec";

export type CliErrorKind = "validation" | "not_found" | "dependency" | "runtime";

interface CliErrorOptions {
  kind: CliErrorKind;
  message: string;
  hint?: string;
  detail?: string;
  exitCode?: number;
}

export class CliError extends Error {
  readonly kind: CliErrorKind;
  readonly hint?: string;
  readonly detail?: string;
  readonly exitCode: number;

  constructor(options: CliErrorOptions) {
    super(options.message);
    this.name = "CliError";
    this.kind = options.kind;
    this.hint = options.hint;
    this.detail = options.detail;
    this.exitCode = options.exitCode ?? 1;
  }
}

export function toCliError(error: unknown): CliError {
  if (error instanceof CliError) {
    return error;
  }

  if (error instanceof CommandError) {
    const detail = [error.stdout, error.stderr].filter(Boolean).join("\n");
    return new CliError({
      kind: "runtime",
      message: error.message,
      detail: detail || undefined
    });
  }

  if (error instanceof Error) {
    return new CliError({
      kind: "runtime",
      message: error.message
    });
  }

  return new CliError({
    kind: "runtime",
    message: String(error)
  });
}

export function renderCliError(error: CliError): string {
  const lines = [error.message];
  if (error.hint) {
    lines.push(`Hint: ${error.hint}`);
  }
  if (error.detail) {
    lines.push(error.detail);
  }
  return lines.join("\n");
}
