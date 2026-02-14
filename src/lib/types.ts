export type InstanceStatus = "running" | "stopped" | "unknown";

export interface InstanceInfo {
  name: string;
  internalName: string;
  status: InstanceStatus;
  ip?: string;
  ramGb?: number;
  mountPath?: string;
  createdAt?: Date;
  startedAt?: Date;
}

export interface RamPolicyComputation {
  totalGb: number;
  allocatedGb: number;
  requestedGb: number;
  remainingGb: number;
  reserveFloorGb: number;
  allowed: boolean;
}
