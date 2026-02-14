export const CLI_NAME = "clawbox";
export const INSTANCE_PREFIX = "clawbox-";

export const DEFAULT_IMAGE_TAG = "clawbox/default:latest";
export const DEFAULT_TEMPLATE_MOUNT_PATH = "/mnt/host";

export const RAM_OPTIONS_GB = [4, 5, 6] as const;
export const DEFAULT_RAM_GB = 4;
export const HOST_RAM_FLOOR_GB = 8;

export const MANAGED_LABEL = "com.clawbox.managed";
export const INSTANCE_NAME_LABEL = "com.clawbox.instance-name";
export const INSTANCE_RAM_LABEL = "com.clawbox.ram-gb";
export const INSTANCE_MOUNT_LABEL = "com.clawbox.mount-path";
export const INSTANCE_CREATED_AT_LABEL = "com.clawbox.created-at";

// macOS 26 (Tahoe) reports Darwin 25.x.
export const MIN_SUPPORTED_DARWIN_MAJOR = 25;
