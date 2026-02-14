export function renderTable(headers: string[], rows: string[][]): string {
  if (rows.length === 0) {
    return "";
  }

  const widths = headers.map((header, idx) => {
    const cellLengths = rows.map((row) => (row[idx] ?? "").length);
    return Math.max(header.length, ...cellLengths);
  });

  const headerLine = headers.map((header, idx) => header.padEnd(widths[idx])).join("  ");
  const divider = widths.map((width) => "-".repeat(width)).join("  ");
  const body = rows
    .map((row) => row.map((cell, idx) => (cell ?? "").padEnd(widths[idx])).join("  "))
    .join("\n");

  return `${headerLine}\n${divider}\n${body}`;
}
