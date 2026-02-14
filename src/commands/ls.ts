import { Command } from "commander";
import { getCommandContext } from "../lib/command-context";
import { listManagedInstances } from "../lib/instances";
import { formatGb } from "../lib/utils";
import { renderTable } from "../lib/table";

export function registerLsCommand(program: Command): void {
  program
    .command("ls")
    .description("List all clawbox instances")
    .action(async () => {
      const { containerBin } = await getCommandContext();

      const instances = await listManagedInstances(containerBin);
      if (instances.length === 0) {
        console.log("No clawbox instances found.");
        return;
      }

      const rows = instances.map((instance) => [
        instance.name,
        instance.status,
        instance.keepAwake === false ? "normal" : "keep-awake",
        instance.ip ?? "-",
        formatGb(instance.ramGb),
        instance.mountPath ?? "-"
      ]);

      console.log(renderTable(["NAME", "STATUS", "HOST SLEEP", "IP", "RAM", "MOUNT"], rows));
    });
}
